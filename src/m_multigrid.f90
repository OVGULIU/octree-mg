#include "cpp_macros.h"
module m_multigrid
  use m_data_structures
  use m_prolong
  use m_restrict
  use m_ghost_cells

  implicit none
  private

  integer, parameter :: smoother_type   = 3
  integer, parameter :: smoother_gsrb   = 1
  integer, parameter :: smoother_jacobi = 2
  integer, parameter :: smoother_gs     = 3

  integer :: timer_total         = -1
  integer :: timer_smoother      = -1
  integer :: timer_smoother_gc   = -1
  integer :: timer_coarse        = -1
  integer :: timer_correct       = -1
  integer :: timer_update_coarse = -1

  ! Public methods
  public :: mg_fas_vcycle
  public :: mg_fas_fmg
  public :: box_lpl

contains

  subroutine mg_add_timers(mg)
    type(mg_t), intent(inout) :: mg
    timer_total         = add_timer(mg, "mg total")
    timer_smoother      = add_timer(mg, "mg smoother")
    timer_smoother_gc   = add_timer(mg, "mg smoother g.c.")
    timer_coarse        = add_timer(mg, "mg coarse")
    timer_correct       = add_timer(mg, "mg correct")
    timer_update_coarse = add_timer(mg, "mg update coarse")
  end subroutine mg_add_timers

  !> Perform FAS-FMG cycle (full approximation scheme, full multigrid). Note
  !> that this routine needs valid ghost cells (for i_phi) on input, and gives
  !> back valid ghost cells on output
  subroutine mg_fas_fmg(mg, set_residual, have_guess)
    type(mg_t), intent(inout) :: mg
    logical, intent(in)       :: set_residual !< If true, store residual in i_tmp
    logical, intent(in)       :: have_guess   !< If false, start from phi = 0
    integer                   :: lvl, min_lvl, i, id

    min_lvl = 1

    if (.not. have_guess) then
       do lvl = mg%highest_lvl, 1
          do i = 1, size(mg%lvls(lvl)%my_ids)
             id = mg%lvls(lvl)%my_ids(i)
             mg%boxes(id)%cc(DTIMES(:), i_phi) = 0.0_dp
          end do
       end do
    end if

    do lvl = mg%highest_lvl,  min_lvl+1, -1
       ! Set rhs on coarse grid and restrict phi
       call update_coarse(mg, lvl)
    end do

    do lvl = min_lvl, mg%highest_lvl
       ! Store phi_old
       do i = 1, size(mg%lvls(lvl)%my_ids)
          id = mg%lvls(lvl)%my_ids(i)
          mg%boxes(id)%cc(DTIMES(:), i_old) = &
            mg%boxes(id)%cc(DTIMES(:), i_phi)
       end do

       if (lvl > min_lvl) then
          ! Correct solution at this lvl using lvl-1 data
          ! phi = phi + prolong(phi_coarse - phi_old_coarse)
          call correct_children(mg, lvl-1)

          ! Update ghost cells
          call fill_ghost_cells_lvl(mg, lvl)
       end if

       ! Perform V-cycle, only set residual on last iteration
       call mg_fas_vcycle(mg, &
            set_residual .and. lvl == mg%highest_lvl, lvl)
    end do
  end subroutine mg_fas_fmg

  !> Perform FAS V-cycle (full approximation scheme). Note that this routine
  !> needs valid ghost cells (for i_phi) on input, and gives back valid ghost
  !> cells on output
  subroutine mg_fas_vcycle(mg, set_residual, highest_lvl)
    type(mg_t), intent(inout)     :: mg
    logical, intent(in)           :: set_residual !< If true, store residual in i_res
    integer, intent(in), optional :: highest_lvl  !< Maximum level for V-cycle
    integer                       :: lvl, min_lvl, i, id, max_lvl, nc
    real(dp)                      :: res, init_res

    if (timer_smoother == -1) then
       call mg_add_timers(mg)
    end if

    call timer_start(mg%timers(timer_total))

    min_lvl = mg%lowest_lvl
    max_lvl = mg%highest_lvl
    if (present(highest_lvl)) max_lvl = highest_lvl

    do lvl = max_lvl,  min_lvl+1, -1
       ! Downwards relaxation
       call smooth_boxes(mg, lvl, mg%n_cycle_down)

       ! Set rhs on coarse grid, restrict phi, and copy i_phi to i_old for the
       ! correction later
       call timer_start(mg%timers(timer_update_coarse))
       call update_coarse(mg, lvl)
       call timer_end(mg%timers(timer_update_coarse))
    end do

    call timer_start(mg%timers(timer_coarse))

    ! Coarse grid is on the root
    if (mg%my_rank == 0) then
       init_res = max_residual(mg, 1)
       do i = 1, mg%max_coarse_cycles
          call smooth_boxes(mg, min_lvl, mg%n_cycle_up+mg%n_cycle_down)
          res = max_residual(mg, min_lvl)

          if (res < mg%residual_coarse_rel * init_res .or. &
               res < mg%residual_coarse_abs) exit
       end do
    end if
    call timer_end(mg%timers(timer_coarse))

    ! Do the upwards part of the v-cycle in the tree
    do lvl = min_lvl+1, max_lvl
       ! Correct solution at this lvl using lvl-1 data
       ! phi = phi + prolong(phi_coarse - phi_old_coarse)
       call timer_start(mg%timers(timer_correct))
       call correct_children(mg, lvl-1)

       ! Have to fill ghost cells after correction
       call fill_ghost_cells_lvl(mg, lvl)
       call timer_end(mg%timers(timer_correct))

       ! Upwards relaxation
       call smooth_boxes(mg, lvl, mg%n_cycle_up)
    end do

    if (set_residual) then
       do lvl = min_lvl, max_lvl
          nc = mg%box_size_lvl(lvl)
          do i = 1, size(mg%lvls(lvl)%my_ids)
             id = mg%lvls(lvl)%my_ids(i)
             call residual_box(mg, id, nc)
          end do
       end do
    end if

    call timer_end(mg%timers(timer_total))
  end subroutine mg_fas_vcycle

  real(dp) function max_residual(mg, lvl)
    type(mg_t), intent(inout) :: mg
    integer, intent(in)       :: lvl
    integer                   :: i, id, nc
    real(dp)                  :: res

    nc           = mg%box_size_lvl(lvl)
    max_residual = 0.0_dp

    do i = 1, size(mg%lvls(lvl)%my_ids)
       id = mg%lvls(lvl)%my_ids(i)
       call residual_box(mg, id, nc)
       res = maxval(abs(mg%boxes(id)%cc(DTIMES(1:nc), i_res)))
       max_residual = max(max_residual, res)
    end do
  end function max_residual

  subroutine solve_coarse_grid(mg)
    type(mg_t), intent(inout) :: mg

    real(dp) :: rhs(DTIMES(mg%box_size))
    real(dp) :: rmin(NDIM), rmax(NDIM)
    integer  :: nc, nx(NDIM), my_boxes, total_boxes

    my_boxes    = size(mg%lvls(1)%my_ids)
    total_boxes = size(mg%lvls(1)%ids)
    nc          = mg%box_size

    if (my_boxes == total_boxes) then
       nx(:) = nc
       rmin  = [DTIMES(0.0_dp)]
       rmax  = mg%dr(1) * [DTIMES(nc)]
       rhs   = mg%boxes(1)%cc(DTIMES(1:nc), i_rhs)

#if NDIM == 2
       call fishpack_2d(nx, rhs, mg%bc, rmin, rmax)
#elif NDIM == 3
       call fishpack_3d(nx, rhs, mg%bc, rmin, rmax)
#endif

       mg%boxes(1)%cc(DTIMES(1:nc), i_phi) = rhs
    else if (my_boxes > 0) then
       error stop "Boxes at level 1 at different processors"
    end if

    call fill_ghost_cells_lvl(mg, 1)
  end subroutine solve_coarse_grid

  !> Perform Gauss-Seidel relaxation on box for a Laplacian operator
  subroutine box_gsrb_lpl(mg, id, nc, redblack_cntr)
    type(mg_t), intent(inout) :: mg
    integer, intent(in)       :: id
    integer, intent(in)       :: nc
    integer, intent(in)       :: redblack_cntr !< Iteration counter
    integer                   :: IJK, i0
    real(dp)                  :: dx2
#if NDIM == 3
    real(dp), parameter       :: sixth = 1/6.0_dp
#endif

    dx2 = mg%dr(mg%boxes(id)%lvl)**2

    ! The parity of redblack_cntr determines which cells we use. If
    ! redblack_cntr is even, we use the even cells and vice versa.
    associate (box => mg%boxes(id))
#if NDIM == 2
      do j = 1, nc
         i0 = 2 - iand(ieor(redblack_cntr, j), 1)
         do i = i0, nc, 2
            box%cc(i, j, i_phi) = 0.25_dp * ( &
                 box%cc(i+1, j, i_phi) + box%cc(i-1, j, i_phi) + &
                 box%cc(i, j+1, i_phi) + box%cc(i, j-1, i_phi) - &
                 dx2 * box%cc(i, j, i_rhs))
         end do
      end do
#elif NDIM == 3
      do k = 1, nc
         do j = 1, nc
            i0 = 2 - iand(ieor(redblack_cntr, k+j), 1)
            do i = i0, nc, 2
               box%cc(i, j, k, i_phi) = sixth * ( &
                    box%cc(i+1, j, k, i_phi) + box%cc(i-1, j, k, i_phi) + &
                    box%cc(i, j+1, k, i_phi) + box%cc(i, j-1, k, i_phi) + &
                    box%cc(i, j, k+1, i_phi) + box%cc(i, j, k-1, i_phi) - &
                    dx2 * box%cc(i, j, k, i_rhs))
            end do
         end do
      end do
#endif
    end associate
  end subroutine box_gsrb_lpl

  !> Perform Gauss-Seidel relaxation on box for a Laplacian operator
  subroutine box_gs_lpl(mg, id, nc)
    type(mg_t), intent(inout) :: mg
    integer, intent(in)       :: id
    integer, intent(in)       :: nc
    integer                   :: IJK
    real(dp)                  :: dx2
#if NDIM == 3
    real(dp), parameter       :: sixth = 1/6.0_dp
#endif

    dx2 = mg%dr(mg%boxes(id)%lvl)**2

    ! The parity of redblack_cntr determines which cells we use. If
    ! redblack_cntr is even, we use the even cells and vice versa.
    associate (box => mg%boxes(id))
#if NDIM == 2
      do j = 1, nc
         do i = 1, nc
            box%cc(i, j, i_phi) = 0.25_dp * ( &
                 box%cc(i+1, j, i_phi) + box%cc(i-1, j, i_phi) + &
                 box%cc(i, j+1, i_phi) + box%cc(i, j-1, i_phi) - &
                 dx2 * box%cc(i, j, i_rhs))
         end do
      end do
#elif NDIM == 3
      do k = 1, nc
         do j = 1, nc
            do i = 1, nc
               box%cc(i, j, k, i_phi) = sixth * ( &
                    box%cc(i+1, j, k, i_phi) + box%cc(i-1, j, k, i_phi) + &
                    box%cc(i, j+1, k, i_phi) + box%cc(i, j-1, k, i_phi) + &
                    box%cc(i, j, k+1, i_phi) + box%cc(i, j, k-1, i_phi) - &
                    dx2 * box%cc(i, j, k, i_rhs))
            end do
         end do
      end do
#endif
    end associate
  end subroutine box_gs_lpl

  !> Perform Jacobi relaxation on box for a Laplacian operator
  subroutine box_jacobi_lpl(mg, id, nc)
    type(mg_t), intent(inout) :: mg
    integer, intent(in)       :: id
    integer, intent(in)       :: nc
    integer                   :: IJK
    real(dp), parameter       :: w     = 2.0_dp / 3
    real(dp)                  :: tmp(DTIMES(0:nc+1))
    real(dp)                  :: dx2
#if NDIM == 3
    real(dp), parameter       :: sixth = 1/6.0_dp
#endif

    dx2   = mg%dr(mg%boxes(id)%lvl)**2

    associate (box => mg%boxes(id))
      tmp = box%cc(DTIMES(:), i_phi)
      do KJI_DO(1, nc)
#if NDIM == 2
         box%cc(i, j, i_phi) = (1-w) * box%cc(i, j, i_phi) + &
              0.25_dp * w * ( &
              tmp(i+1, j) + tmp(i-1, j) + &
              tmp(i, j+1) + tmp(i, j-1) - &
              dx2 * box%cc(i, j, i_rhs))
#elif NDIM == 3
         box%cc(i, j, k, i_phi) = (1-w) * &
              box%cc(i, j, k, i_phi) + &
              sixth * w * ( &
              tmp(i+1, j, k) + tmp(i-1, j, k) + &
              tmp(i, j+1, k) + tmp(i, j-1, k) + &
              tmp(i, j, k+1) + tmp(i, j, k-1) - &
              dx2 * box%cc(i, j, k, i_rhs))
#endif
      end do; CLOSE_DO
    end associate
  end subroutine box_jacobi_lpl

  !> Perform Laplacian operator on a box
  subroutine box_lpl(mg, id, nc, i_out)
    type(mg_t), intent(inout) :: mg
    integer, intent(in)       :: id
    integer, intent(in)       :: nc
    integer, intent(in)       :: i_out !< Index of variable to store Laplacian in
    integer                   :: IJK
    real(dp)                  :: inv_dr_sq

    inv_dr_sq = 1 / mg%dr(mg%boxes(id)%lvl)**2

    associate (box => mg%boxes(id))
#if NDIM == 2
      do j = 1, nc
         do i = 1, nc
            box%cc(i, j, i_out) = inv_dr_sq * (box%cc(i-1, j, i_phi) + &
                 box%cc(i+1, j, i_phi) + box%cc(i, j-1, i_phi) + &
                 box%cc(i, j+1, i_phi) - 4 * box%cc(i, j, i_phi))
         end do
      end do
#elif NDIM == 3
      do k = 1, nc
         do j = 1, nc
            do i = 1, nc
               box%cc(i, j, k, i_out) = inv_dr_sq * &
                    (box%cc(i-1, j, k, i_phi) + &
                    box%cc(i+1, j, k, i_phi) + box%cc(i, j-1, k, i_phi) + &
                    box%cc(i, j+1, k, i_phi) + box%cc(i, j, k-1, i_phi) + &
                    box%cc(i, j, k+1, i_phi) - 6 * box%cc(i, j, k, i_phi))
            end do
         end do
      end do
#endif
    end associate
  end subroutine box_lpl

  ! Set rhs on coarse grid, restrict phi, and copy i_phi to i_old for the
  ! correction later
  subroutine update_coarse(mg, lvl)
    type(mg_t), intent(inout) :: mg     !< Tree containing full grid
    integer, intent(in)       :: lvl !< Update coarse values at lvl-1
    integer                   :: i, id, nc, nc_c

    nc   = mg%box_size_lvl(lvl)
    nc_c = mg%box_size_lvl(lvl-1)

    ! Compute residual
    do i = 1, size(mg%lvls(lvl)%my_ids)
       id = mg%lvls(lvl)%my_ids(i)
       call residual_box(mg, id, nc)
    end do

    ! Restrict phi and the residual
    call restrict(mg, i_phi, lvl)
    call restrict(mg, i_res, lvl)

    call fill_ghost_cells_lvl(mg, lvl-1)

    ! Set rhs_c = laplacian(phi_c) + restrict(res) where it is refined, and
    ! store current coarse phi in old.
    do i = 1, size(mg%lvls(lvl-1)%my_parents)
       id = mg%lvls(lvl-1)%my_parents(i)

       ! Set rhs = L phi
       call box_lpl(mg, id, nc_c, i_rhs)

       ! Add the fine grid residual to rhs
       mg%boxes(id)%cc(DTIMES(:), i_rhs) = &
            mg%boxes(id)%cc(DTIMES(:), i_rhs) + &
            mg%boxes(id)%cc(DTIMES(:), i_res)

       ! Story a copy of phi
       mg%boxes(id)%cc(DTIMES(:), i_old) = &
            mg%boxes(id)%cc(DTIMES(:), i_phi)
    end do
  end subroutine update_coarse

  ! Sets phi = phi + prolong(phi_coarse - phi_old_coarse)
  subroutine correct_children(mg, lvl)
    type(mg_t), intent(inout) :: mg
    integer, intent(in)       :: lvl
    integer                   :: i, id

    do i = 1, size(mg%lvls(lvl)%my_parents)
       id = mg%lvls(lvl)%my_parents(i)

       ! Store the correction in i_res
       mg%boxes(id)%cc(DTIMES(:), i_res) = &
            mg%boxes(id)%cc(DTIMES(:), i_phi) - &
            mg%boxes(id)%cc(DTIMES(:), i_old)
    end do

    call prolong(mg, lvl, i_res, i_phi, add=.true.)
  end subroutine correct_children

  subroutine smooth_boxes(mg, lvl, n_cycle)
    type(mg_t), intent(inout) :: mg
    integer, intent(in)       :: lvl
    integer, intent(in)       :: n_cycle !< Number of cycles to perform
    integer                   :: n, i, id, nc

    nc = mg%box_size_lvl(lvl)

    select case (smoother_type)
    case (smoother_jacobi, smoother_gs)
       do n = 1, n_cycle
          call timer_start(mg%timers(timer_smoother))
          do i = 1, size(mg%lvls(lvl)%my_ids)
             id = mg%lvls(lvl)%my_ids(i)
             if (smoother_type == smoother_jacobi) then
                call box_jacobi_lpl(mg, id, nc)
             else
                call box_gs_lpl(mg, id, nc)
             end if
          end do
          call timer_end(mg%timers(timer_smoother))
          call timer_start(mg%timers(timer_smoother_gc))
          call fill_ghost_cells_lvl(mg, lvl)
          call timer_end(mg%timers(timer_smoother_gc))
       end do
    case (smoother_gsrb)
       do n = 1, 2 * n_cycle
          call timer_start(mg%timers(timer_smoother))
          do i = 1, size(mg%lvls(lvl)%my_ids)
             id = mg%lvls(lvl)%my_ids(i)
             call box_gsrb_lpl(mg, id, nc, n)
          end do
          call timer_end(mg%timers(timer_smoother))

          call timer_start(mg%timers(timer_smoother_gc))
          call fill_ghost_cells_lvl(mg, lvl)
          call timer_end(mg%timers(timer_smoother_gc))
       end do
    end select
  end subroutine smooth_boxes

  subroutine residual_box(mg, id, nc)
    type(mg_t), intent(inout) :: mg
    integer, intent(in)       :: id
    integer, intent(in)       :: nc

    call box_lpl(mg, id, nc, i_res)

    mg%boxes(id)%cc(DTIMES(1:nc), i_res) = &
         mg%boxes(id)%cc(DTIMES(1:nc), i_rhs) &
         - mg%boxes(id)%cc(DTIMES(1:nc), i_res)
  end subroutine residual_box

end module m_multigrid
