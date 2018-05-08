#include "cpp_macros.h"
module m_ghost_cells
  use m_data_structures

  implicit none
  private

  ! Public methods
  public :: mg_ghost_cell_buffer_size
  public :: mg_fill_ghost_cells
  public :: mg_fill_ghost_cells_lvl

contains

  !> Specify minimum buffer size (per process) for communication
  subroutine mg_ghost_cell_buffer_size(mg, n_send, n_recv, dsize)
    type(mg_t), intent(inout) :: mg
    integer, intent(out)      :: n_send(0:mg%n_cpu-1)
    integer, intent(out)      :: n_recv(0:mg%n_cpu-1)
    integer, intent(out)      :: dsize
    integer                   :: i, id, lvl, nc

    allocate(mg%comm_ghostcell%n_send(0:mg%n_cpu-1, &
         mg%first_normal_lvl:mg%highest_lvl))
    allocate(mg%comm_ghostcell%n_recv(0:mg%n_cpu-1, &
         mg%first_normal_lvl:mg%highest_lvl))

    dsize = mg%box_size**(NDIM-1)

    do lvl = mg%first_normal_lvl, mg%highest_lvl
       nc               = mg%box_size_lvl(lvl)
       mg%buf(:)%i_send = 0
       mg%buf(:)%i_recv = 0
       mg%buf(:)%i_ix   = 0

       do i = 1, size(mg%lvls(lvl)%my_ids)
          id = mg%lvls(lvl)%my_ids(i)
          call buffer_ghost_cells(mg, id, nc, 1, dry_run=.true.)
       end do

       if (lvl > 1) then
          do i = 1, size(mg%lvls(lvl-1)%my_ref_bnds)
             id = mg%lvls(lvl-1)%my_ref_bnds(i)
             call buffer_refinement_boundaries(mg, id, nc, 1, dry_run=.true.)
          end do
       end if

       ! Set ghost cells to received data
       mg%buf(:)%i_recv = 0
       do i = 1, size(mg%lvls(lvl)%my_ids)
          id = mg%lvls(lvl)%my_ids(i)
          call set_ghost_cells(mg, id, nc, 1, dry_run=.true.)
       end do

       mg%comm_ghostcell%n_send(:, lvl) = mg%buf(:)%i_send/dsize
       mg%comm_ghostcell%n_recv(:, lvl) = mg%buf(:)%i_recv/dsize
    end do

    n_send = maxval(mg%comm_ghostcell%n_send, dim=2)
    n_recv = maxval(mg%comm_ghostcell%n_recv, dim=2)
  end subroutine mg_ghost_cell_buffer_size

  !> Fill ghost cells at all grid levels
  subroutine mg_fill_ghost_cells(mg, iv)
    type(mg_t)          :: mg
    integer, intent(in) :: iv !< Index of variable
    integer             :: lvl

    do lvl = mg%lowest_lvl, mg%highest_lvl
       call mg_fill_ghost_cells_lvl(mg, lvl, iv)
    end do
  end subroutine mg_fill_ghost_cells

  !> Fill ghost cells at a grid level
  subroutine mg_fill_ghost_cells_lvl(mg, lvl, iv)
    use m_communication
    use mpi
    type(mg_t)                   :: mg
    integer, intent(in)          :: lvl
    integer, intent(in)          :: iv !< Index of variable
    integer                      :: i, id, dsize, nc

    if (lvl < mg%lowest_lvl) &
         error stop "fill_ghost_cells_lvl: lvl < lowest_lvl"
    if (lvl > mg%highest_lvl) &
         error stop "fill_ghost_cells_lvl: lvl > highest_lvl"

    nc               = mg%box_size_lvl(lvl)

    if (lvl >= mg%first_normal_lvl) then
       dsize            = nc**(NDIM-1)
       mg%buf(:)%i_send = 0
       mg%buf(:)%i_recv = 0
       mg%buf(:)%i_ix   = 0

       do i = 1, size(mg%lvls(lvl)%my_ids)
          id = mg%lvls(lvl)%my_ids(i)
          call buffer_ghost_cells(mg, id, nc, iv, .false.)
       end do

       if (lvl > 1) then
          do i = 1, size(mg%lvls(lvl-1)%my_ref_bnds)
             id = mg%lvls(lvl-1)%my_ref_bnds(i)
             call buffer_refinement_boundaries(mg, id, nc, iv, .false.)
          end do
       end if

       ! Transfer data between processes
       mg%buf(:)%i_recv = mg%comm_ghostcell%n_recv(:, lvl) * dsize
       call sort_and_transfer_buffers(mg, dsize)

       ! Set ghost cells to received data
       mg%buf(:)%i_recv = 0
    end if

    do i = 1, size(mg%lvls(lvl)%my_ids)
       id = mg%lvls(lvl)%my_ids(i)
       call set_ghost_cells(mg, id, nc, iv, .false.)
    end do
  end subroutine mg_fill_ghost_cells_lvl

  subroutine buffer_ghost_cells(mg, id, nc, iv, dry_run)
    type(mg_t), intent(inout) :: mg
    integer, intent(in)       :: id
    integer, intent(in)       :: nc
    integer, intent(in)       :: iv
    logical, intent(in)       :: dry_run
    integer                   :: nb, nb_id, nb_rank

    do nb = 1, num_neighbors
       nb_id = mg%boxes(id)%neighbors(nb)

       if (nb_id > no_box) then
          ! There is a neighbor
          nb_rank    = mg%boxes(nb_id)%rank

          if (nb_rank /= mg%my_rank) then
             call buffer_for_nb(mg, mg%boxes(id), nc, iv, nb_id, nb_rank, &
                  nb, dry_run)
          end if
       end if
    end do
  end subroutine buffer_ghost_cells

  subroutine buffer_refinement_boundaries(mg, id, nc, iv, dry_run)
    type(mg_t), intent(inout) :: mg
    integer, intent(in)       :: id
    integer, intent(in)       :: nc
    integer, intent(in)       :: iv
    logical, intent(in)       :: dry_run
    integer                   :: nb, nb_id, c_ids(2**(NDIM-1))
    integer                   :: n, c_id, c_rank

    do nb = 1, num_neighbors
       nb_id = mg%boxes(id)%neighbors(nb)
       if (nb_id > no_box) then
          if (has_children(mg%boxes(nb_id))) then
             c_ids = mg%boxes(nb_id)%children(child_adj_nb(:, neighb_rev(nb)))

             do n = 1, num_children/2
                c_id = c_ids(n)
                c_rank = mg%boxes(c_id)%rank

                if (c_rank /= mg%my_rank) then
                   ! Send all coarse ghost cells
                   call buffer_for_nb(mg, mg%boxes(id), nc, iv, c_id, &
                        c_rank, nb, dry_run)
                end if
             end do
          end if
       end if
    end do
  end subroutine buffer_refinement_boundaries

  subroutine set_ghost_cells(mg, id, nc, iv, dry_run)
    type(mg_t), intent(inout)    :: mg
    integer, intent(in)          :: id
    integer, intent(in)          :: nc
    integer, intent(in)          :: iv
    logical, intent(in)          :: dry_run
    integer                      :: nb, nb_id, nb_rank, bc_type

    do nb = 1, num_neighbors
       nb_id = mg%boxes(id)%neighbors(nb)

       if (nb_id > no_box) then
          ! There is a neighbor
          nb_rank    = mg%boxes(nb_id)%rank

          if (nb_rank /= mg%my_rank) then
             call fill_buffered_nb(mg, mg%boxes(id), nb_rank, &
                  nb, nc, iv, dry_run)
          else if (.not. dry_run) then
             call copy_from_nb(mg%boxes(id), mg%boxes(nb_id), &
                  nb, nc, iv)
          end if
       else if (nb_id == no_box) then
          ! Refinement boundary
          call fill_refinement_bnd(mg, id, nb, nc, iv, dry_run)
       else if (.not. dry_run) then
          ! Physical boundary
          if (associated(mg%bc(nb, iv)%boundary_cond)) then
             call mg%bc(nb, iv)%boundary_cond(mg, id, nc, iv, nb, bc_type)
          else
             bc_type = mg%bc(nb, iv)%bc_type
             call box_set_gc_scalar(mg%boxes(id), nb, nc, iv, &
                     mg%bc(nb, iv)%bc_value)
          end if
          call bc_to_gc(mg, id, nc, iv, nb, bc_type)
       end if
    end do
  end subroutine set_ghost_cells

  subroutine fill_refinement_bnd(mg, id, nb, nc, iv, dry_run)
    type(mg_t), intent(inout) :: mg
    integer, intent(in)       :: id
    integer, intent(in)       :: nc
    integer, intent(in)       :: iv
    integer, intent(in)       :: nb
    logical, intent(in)       :: dry_run
    real(dp)                  :: cgc(nc)
    integer                   :: p_id, p_nb_id
    integer                   :: i, dsize, p_nb_rank

    dsize     = nc**(NDIM-1)
    p_id      = mg%boxes(id)%parent
    p_nb_id   = mg%boxes(p_id)%neighbors(nb)
    p_nb_rank = mg%boxes(p_nb_id)%rank

    if (p_nb_rank /= mg%my_rank) then
       i = mg%buf(p_nb_rank)%i_recv
       if (.not. dry_run) then
          cgc = mg%buf(p_nb_rank)%recv(i+1:i+dsize)
       end if
       mg%buf(p_nb_rank)%i_recv = mg%buf(p_nb_rank)%i_recv + dsize
    else if (.not. dry_run) then
       call box_gc_for_neighbor(mg%boxes(p_nb_id), neighb_rev(nb), &
            nc, iv, cgc)
    end if

    if (.not. dry_run) then
       if (associated(mg%bc(nb, iv)%refinement_bnd)) then
          call mg%bc(nb, iv)%refinement_bnd(mg, id, nc, iv, nb, cgc)
       else
          call sides_rb(mg, id, nc, iv, nb, cgc)
       end if
    end if
  end subroutine fill_refinement_bnd

  subroutine copy_from_nb(box, box_nb, nb, nc, iv)
    type(box_t), intent(inout) :: box
    type(box_t), intent(in)    :: box_nb
    integer, intent(in)        :: nb
    integer, intent(in)        :: nc
    integer, intent(in)        :: iv
#if NDIM == 2
    real(dp)                   :: gc(nc)
#elif NDIM == 3
    real(dp)                   :: gc(nc, nc)
#endif

    call box_gc_for_neighbor(box_nb, neighb_rev(nb), nc, iv, gc)
    call box_set_gc(box, nb, nc, iv, gc)
  end subroutine copy_from_nb

  subroutine buffer_for_nb(mg, box, nc, iv, nb_id, nb_rank, nb, dry_run)
    use mpi
    type(mg_t), intent(inout)  :: mg
    type(box_t), intent(inout) :: box
    integer, intent(in)        :: nc
    integer, intent(in)        :: iv
    integer, intent(in)        :: nb_id
    integer, intent(in)        :: nb_rank
    integer, intent(in)        :: nb
    logical, intent(in)        :: dry_run
    integer                    :: i, dsize
#if NDIM == 2
    real(dp)                   :: gc(nc)
#elif NDIM == 3
    real(dp)                   :: gc(nc, nc)
#endif

    i     = mg%buf(nb_rank)%i_send
    dsize = nc**(NDIM-1)

    if (.not. dry_run) then
       call box_gc_for_neighbor(box, nb, nc, iv, gc)
       mg%buf(nb_rank)%send(i+1:i+dsize) = pack(gc, .true.)
    end if

    ! Later the buffer is sorted, using the fact that loops go from low to high
    ! box id, and we fill ghost cells according to the neighbor order
    i = mg%buf(nb_rank)%i_ix
    if (.not. dry_run) then
       mg%buf(nb_rank)%ix(i+1) = num_neighbors * nb_id + neighb_rev(nb)
    end if

    mg%buf(nb_rank)%i_send = mg%buf(nb_rank)%i_send + dsize
    mg%buf(nb_rank)%i_ix   = mg%buf(nb_rank)%i_ix + 1
  end subroutine buffer_for_nb

  subroutine fill_buffered_nb(mg, box, nb_rank, nb, nc, iv, dry_run)
    use mpi
    type(mg_t), intent(inout)  :: mg
    type(box_t), intent(inout) :: box
    integer, intent(in)        :: nb_rank
    integer, intent(in)        :: nb
    integer, intent(in)        :: nc
    integer, intent(in)        :: iv
    logical, intent(in)        :: dry_run
    integer                    :: i, dsize
#if NDIM == 2
    real(dp)                   :: gc(nc)
#elif NDIM == 3
    real(dp)                   :: gc(nc, nc)
#endif

    i     = mg%buf(nb_rank)%i_recv
    dsize = nc**(NDIM-1)

    if (.not. dry_run) then
       gc = reshape(mg%buf(nb_rank)%recv(i+1:i+dsize), shape(gc))
       call box_set_gc(box, nb, nc, iv, gc)
    end if
    mg%buf(nb_rank)%i_recv = mg%buf(nb_rank)%i_recv + dsize

  end subroutine fill_buffered_nb

  subroutine box_gc_for_neighbor(box, nb, nc, iv, gc)
    type(box_t), intent(in) :: box
    integer, intent(in)     :: nb, nc, iv
#if NDIM == 2
    real(dp), intent(out)   :: gc(nc)
#elif NDIM == 3
    real(dp), intent(out)   :: gc(nc, nc)
#endif

    select case (nb)
#if NDIM == 2
    case (neighb_lowx)
       gc = box%cc(1, 1:nc, iv)
    case (neighb_highx)
       gc = box%cc(nc, 1:nc, iv)
    case (neighb_lowy)
       gc = box%cc(1:nc, 1, iv)
    case (neighb_highy)
       gc = box%cc(1:nc, nc, iv)
#elif NDIM == 3
    case (neighb_lowx)
       gc = box%cc(1, 1:nc, 1:nc, iv)
    case (neighb_highx)
       gc = box%cc(nc, 1:nc, 1:nc, iv)
    case (neighb_lowy)
       gc = box%cc(1:nc, 1, 1:nc, iv)
    case (neighb_highy)
       gc = box%cc(1:nc, nc, 1:nc, iv)
    case (neighb_lowz)
       gc = box%cc(1:nc, 1:nc, 1, iv)
    case (neighb_highz)
       gc = box%cc(1:nc, 1:nc, nc, iv)
#endif
    end select
  end subroutine box_gc_for_neighbor

  subroutine box_set_gc(box, nb, nc, iv, gc)
    type(box_t), intent(inout) :: box
    integer, intent(in)        :: nb, nc, iv
#if NDIM == 2
    real(dp), intent(in)       :: gc(nc)
#elif NDIM == 3
    real(dp), intent(in)       :: gc(nc, nc)
#endif

    select case (nb)
#if NDIM == 2
    case (neighb_lowx)
       box%cc(0, 1:nc, iv)    = gc
    case (neighb_highx)
       box%cc(nc+1, 1:nc, iv) = gc
    case (neighb_lowy)
       box%cc(1:nc, 0, iv)    = gc
    case (neighb_highy)
       box%cc(1:nc, nc+1, iv) = gc
#elif NDIM == 3
    case (neighb_lowx)
       box%cc(0, 1:nc, 1:nc, iv)    = gc
    case (neighb_highx)
       box%cc(nc+1, 1:nc, 1:nc, iv) = gc
    case (neighb_lowy)
       box%cc(1:nc, 0, 1:nc, iv)    = gc
    case (neighb_highy)
       box%cc(1:nc, nc+1, 1:nc, iv) = gc
    case (neighb_lowz)
       box%cc(1:nc, 1:nc, 0, iv)    = gc
    case (neighb_highz)
       box%cc(1:nc, 1:nc, nc+1, iv) = gc
#endif
    end select
  end subroutine box_set_gc

  subroutine box_set_gc_scalar(box, nb, nc, iv, gc)
    type(box_t), intent(inout) :: box
    integer, intent(in)        :: nb, nc, iv
    real(dp), intent(in)       :: gc

    select case (nb)
#if NDIM == 2
    case (neighb_lowx)
       box%cc(0, 1:nc, iv)    = gc
    case (neighb_highx)
       box%cc(nc+1, 1:nc, iv) = gc
    case (neighb_lowy)
       box%cc(1:nc, 0, iv)    = gc
    case (neighb_highy)
       box%cc(1:nc, nc+1, iv) = gc
#elif NDIM == 3
    case (neighb_lowx)
       box%cc(0, 1:nc, 1:nc, iv)    = gc
    case (neighb_highx)
       box%cc(nc+1, 1:nc, 1:nc, iv) = gc
    case (neighb_lowy)
       box%cc(1:nc, 0, 1:nc, iv)    = gc
    case (neighb_highy)
       box%cc(1:nc, nc+1, 1:nc, iv) = gc
    case (neighb_lowz)
       box%cc(1:nc, 1:nc, 0, iv)    = gc
    case (neighb_highz)
       box%cc(1:nc, 1:nc, nc+1, iv) = gc
#endif
    end select
  end subroutine box_set_gc_scalar

  subroutine bc_to_gc(mg, id, nc, iv, nb, bc_type)
    type(mg_t), intent(inout) :: mg
    integer, intent(in)       :: id
    integer, intent(in)       :: nc
    integer, intent(in)       :: iv
    integer, intent(in)       :: nb      !< Neighbor direction
    integer, intent(in)       :: bc_type !< Type of b.c.
    real(dp)                  :: c0, c1, c2, dr

    ! If we call the interior point x1, x2 and the ghost point x0, then a
    ! Dirichlet boundary value b can be imposed as:
    ! x0 = -x1 + 2*b
    ! A Neumann b.c. can be imposed as:
    ! x0 = x1 +/- dx * b
    ! A continuous boundary (same slope) as:
    ! x0 = 2 * x1 - x2
    ! Below, we set coefficients to handle these cases
    select case (bc_type)
    case (bc_dirichlet)
       c0 = 2
       c1 = -1
       c2 = 0
    case (bc_neumann)
       dr = mg%dr(neighb_dim(nb), mg%boxes(id)%lvl)
       c0 = dr * neighb_high_pm(nb) ! This gives a + or - sign
       c1 = 1
       c2 = 0
    case (bc_continuous)
       c0 = 0
       c1 = 2
       c2 = -1
    case default
       error stop "bc_to_gc: unknown boundary condition"
    end select

    select case (nb)
#if NDIM == 2
    case (neighb_lowx)
       mg%boxes(id)%cc(0, 1:nc, iv) = &
            c0 * mg%boxes(id)%cc(0, 1:nc, iv) + &
            c1 * mg%boxes(id)%cc(1, 1:nc, iv) + &
            c2 * mg%boxes(id)%cc(2, 1:nc, iv)
    case (neighb_highx)
       mg%boxes(id)%cc(nc+1, 1:nc, iv) = &
            c0 * mg%boxes(id)%cc(nc+1, 1:nc, iv) + &
            c1 * mg%boxes(id)%cc(nc, 1:nc, iv) + &
            c2 * mg%boxes(id)%cc(nc-1, 1:nc, iv)
    case (neighb_lowy)
       mg%boxes(id)%cc(1:nc, 0, iv) = &
            c0 * mg%boxes(id)%cc(1:nc, 0, iv) + &
            c1 * mg%boxes(id)%cc(1:nc, 1, iv) + &
            c2 * mg%boxes(id)%cc(1:nc, 2, iv)
    case (neighb_highy)
       mg%boxes(id)%cc(1:nc, nc+1, iv) = &
            c0 * mg%boxes(id)%cc(1:nc, nc+1, iv) + &
            c1 * mg%boxes(id)%cc(1:nc, nc, iv) + &
            c2 * mg%boxes(id)%cc(1:nc, nc-1, iv)
#elif NDIM == 3
    case (neighb_lowx)
       mg%boxes(id)%cc(0, 1:nc, 1:nc, iv) = &
            c0 * mg%boxes(id)%cc(0, 1:nc, 1:nc, iv) + &
            c1 * mg%boxes(id)%cc(1, 1:nc, 1:nc, iv) + &
            c2 * mg%boxes(id)%cc(2, 1:nc, 1:nc, iv)
    case (neighb_highx)
       mg%boxes(id)%cc(nc+1, 1:nc, 1:nc, iv) = &
            c0 * mg%boxes(id)%cc(nc+1, 1:nc, 1:nc, iv) + &
            c1 * mg%boxes(id)%cc(nc, 1:nc, 1:nc, iv) + &
            c2 * mg%boxes(id)%cc(nc-1, 1:nc, 1:nc, iv)
    case (neighb_lowy)
       mg%boxes(id)%cc(1:nc, 0, 1:nc, iv) = &
            c0 * mg%boxes(id)%cc(1:nc, 0, 1:nc, iv) + &
            c1 * mg%boxes(id)%cc(1:nc, 1, 1:nc, iv) + &
            c2 * mg%boxes(id)%cc(1:nc, 2, 1:nc, iv)
    case (neighb_highy)
       mg%boxes(id)%cc(1:nc, nc+1, 1:nc, iv) = &
            c0 * mg%boxes(id)%cc(1:nc, nc+1, 1:nc, iv) + &
            c1 * mg%boxes(id)%cc(1:nc, nc, 1:nc, iv) + &
            c2 * mg%boxes(id)%cc(1:nc, nc-1, 1:nc, iv)
    case (neighb_lowz)
       mg%boxes(id)%cc(1:nc, 1:nc, 0, iv) = &
            c0 * mg%boxes(id)%cc(1:nc, 1:nc, 0, iv) + &
            c1 * mg%boxes(id)%cc(1:nc, 1:nc, 1, iv) + &
            c2 * mg%boxes(id)%cc(1:nc, 1:nc, 2, iv)
    case (neighb_highz)
       mg%boxes(id)%cc(1:nc, 1:nc, nc+1, iv) = &
            c0 * mg%boxes(id)%cc(1:nc, 1:nc, nc+1, iv) + &
            c1 * mg%boxes(id)%cc(1:nc, 1:nc, nc, iv) + &
            c2 * mg%boxes(id)%cc(1:nc, 1:nc, nc-1, iv)
#endif
    end select
  end subroutine bc_to_gc

  !> Fill ghost cells near refinement boundaries which preserves diffusive fluxes.
  !>
  !> Basically, we extrapolate from the fine cells to a corner point, and then
  !> take the average between this corner point and a coarse neighbor to fill
  !> ghost cells for the fine cells.
  subroutine sides_rb(mg, id, nc, iv, nb, cgc)
    type(mg_t), intent(inout) :: mg
    integer, intent(in)       :: id !< Id of box
    integer, intent(in)       :: nc
    integer, intent(in)       :: iv
    integer, intent(in)       :: nb !< Ghost cell direction
    !> Unmodified coarse grid ghost cells (including data for neighbors)
#if NDIM == 2
    real(dp), intent(in)      :: cgc(nc)
#elif NDIM == 3
    real(dp), intent(in)      :: cgc(nc, nc)
#endif
    integer                   :: IJK, ix, dix, di, dj
    integer                   :: ix_off(NDIM)
#if NDIM == 3
    integer                   :: dk
#endif

    ix_off = get_child_offset(mg, id)

    if (neighb_low(nb)) then
       ix = 1
       dix = 1
    else
       ix = nc
       dix = -1
    end if

    select case (neighb_dim(nb))
#if NDIM == 2
    case (1)
       i = ix
       di = dix
       do j = 1, nc
          dj = -1 + 2 * iand(j, 1)
          ! Extrapolation using 3 points
          mg%boxes(id)%cc(i-di, j, iv) = 0.5_dp * cgc(ix_off(2)+(j+1)/2) + &
               mg%boxes(id)%cc(i, j, iv) - 0.25_dp * &
               (mg%boxes(id)%cc(i+di, j, iv) + mg%boxes(id)%cc(i, j+dj, iv))

          ! Extrapolation using 2 points
          ! mg%boxes(id)%cc(i-di, j, iv) = 0.5_dp * mg%boxes(id)%cc(i-di, j, iv) + &
          !      0.75_dp * mg%boxes(id)%cc(i, j, iv) - 0.25_dp * &
          !      mg%boxes(id)%cc(i+di, j+dj, iv)
       end do
    case (2)
       j = ix
       dj = dix
       do i = 1, nc
          di = -1 + 2 * iand(i, 1)
          ! Extrapolation using 3 points
          mg%boxes(id)%cc(i, j-dj, iv) = 0.5_dp * cgc(ix_off(1)+(i+1)/2) + &
               mg%boxes(id)%cc(i, j, iv) - 0.25_dp * &
               (mg%boxes(id)%cc(i, j+dj, iv) + mg%boxes(id)%cc(i+di, j, iv))

          ! Extrapolation using 2 points
          ! mg%boxes(id)%cc(i, j-dj, iv) = 0.5_dp * mg%boxes(id)%cc(i, j-dj, iv) + &
          !      0.75_dp * mg%boxes(id)%cc(i, j, iv) - 0.25_dp * &
          !      mg%boxes(id)%cc(i+di, j+dj, iv)
       end do
#elif NDIM == 3
    case (1)
       i = ix
       di = dix
       do k = 1, nc
          dk = -1 + 2 * iand(k, 1)
          do j = 1, nc
             dj = -1 + 2 * iand(j, 1)
             ! Trilinear extrapolation (using 8 points)
             ! boxes(id)%cc(i-di, j, k, iv) = &
             !      0.5_dp * boxes(id)%cc(i-di, j, k, iv) + 0.0625_dp * (&
             !      27 * boxes(id)%cc(i, j, k, iv) &
             !      - 9 * boxes(id)%cc(i+di, j, k, iv) &
             !      - 9 * boxes(id)%cc(i, j+dj, k, iv) &
             !      - 9 * boxes(id)%cc(i, j, k+dk, iv) &
             !      + 3 * boxes(id)%cc(i+di, j+dj, k, iv) &
             !      + 3 * boxes(id)%cc(i+di, j, k+dk, iv) &
             !      + 3 * boxes(id)%cc(i, j+dj, k+dk, iv) &
             !      - 1 * boxes(id)%cc(i+di, j+dj, k+dk, iv))

             ! Extrapolation using 2 points
             mg%boxes(id)%cc(i-di, j, k, iv) = &
                  0.5_dp * cgc(ix_off(2)+(j+1)/2, ix_off(3)+(k+1)/2) + &
                  0.75_dp * mg%boxes(id)%cc(i, j, k, iv) - &
                  0.25_dp * mg%boxes(id)%cc(i+di, j+dj, k+dk, iv)
          end do
       end do
    case (2)
       j = ix
       dj = dix
       do k = 1, nc
          dk = -1 + 2 * iand(k, 1)
          do i = 1, nc
             di = -1 + 2 * iand(i, 1)

             ! boxes(id)%cc(i, j-dj, k, iv) = &
             !      0.5_dp * boxes(id)%cc(i, j-dj, k, iv) + 0.0625_dp * (&
             !      27 * boxes(id)%cc(i, j, k, iv) &
             !      - 9 * boxes(id)%cc(i+di, j, k, iv) &
             !      - 9 * boxes(id)%cc(i, j+dj, k, iv) &
             !      - 9 * boxes(id)%cc(i, j, k+dk, iv) &
             !      + 3 * boxes(id)%cc(i+di, j+dj, k, iv) &
             !      + 3 * boxes(id)%cc(i+di, j, k+dk, iv) &
             !      + 3 * boxes(id)%cc(i, j+dj, k+dk, iv) &
             !      - 1 * boxes(id)%cc(i+di, j+dj, k+dk, iv))

             mg%boxes(id)%cc(i, j-dj, k, iv) = &
                  0.5_dp * cgc(ix_off(1)+(i+1)/2, ix_off(3)+(k+1)/2) + &
                  0.75_dp * mg%boxes(id)%cc(i, j, k, iv) - &
                  0.25_dp * mg%boxes(id)%cc(i+di, j+dj, k+dk, iv)
          end do
       end do
    case (3)
       k = ix
       dk = dix
       do j = 1, nc
          dj = -1 + 2 * iand(j, 1)
          do i = 1, nc
             di = -1 + 2 * iand(i, 1)

             ! boxes(id)%cc(i, j, k-dk, iv) = &
             !      0.5_dp * boxes(id)%cc(i, j, k-dk, iv) + 0.0625_dp * (&
             !      27 * boxes(id)%cc(i, j, k, iv) &
             !      - 9 * boxes(id)%cc(i+di, j, k, iv) &
             !      - 9 * boxes(id)%cc(i, j+dj, k, iv) &
             !      - 9 * boxes(id)%cc(i, j, k+dk, iv) &
             !      + 3 * boxes(id)%cc(i+di, j+dj, k, iv) &
             !      + 3 * boxes(id)%cc(i+di, j, k+dk, iv) &
             !      + 3 * boxes(id)%cc(i, j+dj, k+dk, iv) &
             !      - 1 * boxes(id)%cc(i+di, j+dj, k+dk, iv))

             mg%boxes(id)%cc(i, j, k-dk, iv) = &
                  0.5_dp * cgc(ix_off(1)+(i+1)/2, ix_off(2)+(j+1)/2) + &
                  0.75_dp * mg%boxes(id)%cc(i, j, k, iv) - &
                  0.25_dp * mg%boxes(id)%cc(i+di, j+dj, k+dk, iv)
          end do
       end do
#endif
    end select

  end subroutine sides_rb

end module m_ghost_cells
