module m_ghost_cells
  use m_data_structures

  implicit none
  private

  ! Public methods
  public :: ghost_cell_buffer_size
  public :: fill_ghost_cells_lvl

contains

  !> Specify minimum buffer size (per process) for communication
  subroutine ghost_cell_buffer_size(mg, n_send, n_recv, dsize)
    type(mg_2d_t), intent(in) :: mg
    integer, intent(out)      :: n_send(0:mg%n_cpu-1)
    integer, intent(out)      :: n_recv(0:mg%n_cpu-1)
    integer, intent(out)      :: dsize
    integer                   :: n_msg(0:mg%n_cpu-1, 1:mg%highest_lvl)
    integer                   :: i, id, lvl, nb, nb_id, nb_rank

    n_msg(:, :) = 0

    do lvl = 1, mg%highest_lvl
       do i = 1, size(mg%lvls(lvl)%my_ids)
          id = mg%lvls(lvl)%my_ids(i)

          do nb = 1, num_neighbors
             nb_id = mg%boxes(id)%neighbors(nb)

             if (nb_id > no_box) then
                ! There is a neighbor
                nb_rank    = mg%boxes(nb_id)%rank
                if (nb_rank /= mg%my_rank) then
                   n_msg(nb_rank, lvl) = n_msg(nb_rank, lvl) + 1
                end  if
             end if
          end do
       end do
    end do

    n_send(:) = maxval(n_msg(:, :), dim=2)
    n_recv(:) = n_send(:)
    dsize     = mg%box_size
  end subroutine ghost_cell_buffer_size

  subroutine fill_ghost_cells_lvl(mg, lvl)
    use m_communication
    type(mg_2d_t)        :: mg
    integer, intent(in)  :: lvl
    integer              :: i, id, n

    if (lvl < 1) error stop "fill_ghost_cells_lvl: lvl < 1"
    if (lvl > mg%highest_lvl) error stop "fill_ghost_cells_lvl: lvl > highest_lvl"

    mg%buf(:)%i_send = 0
    mg%buf(:)%i_recv = 0
    mg%buf(:)%i_ix = 0

    n = size(mg%lvls(lvl)%my_ids) * 4

    do i = 1, size(mg%lvls(lvl)%my_ids)
       id = mg%lvls(lvl)%my_ids(i)
       call buffer_ghost_cells(mg, id)
    end do

    ! Transfer data between processes
    mg%buf(:)%i_recv = mg%buf(:)%i_send
    call sort_and_transfer_buffers(mg, mg%box_size)

    ! Set ghost cells to received data
    mg%buf(:)%i_recv = 0
    do i = 1, size(mg%lvls(lvl)%my_ids)
       id = mg%lvls(lvl)%my_ids(i)
       call set_ghost_cells(mg, id)
    end do

  end subroutine fill_ghost_cells_lvl

  subroutine buffer_ghost_cells(mg, id)
    type(mg_2d_t), intent(inout) :: mg
    integer, intent(in)          :: id
    integer                      :: nb, nb_id, nb_rank

    do nb = 1, num_neighbors
       nb_id = mg%boxes(id)%neighbors(nb)

       if (nb_id > no_box) then
          ! There is a neighbor
          nb_rank    = mg%boxes(nb_id)%rank

          if (nb_rank /= mg%my_rank) then
             call buffer_for_nb(mg, mg%boxes(id), nb_id, nb_rank, nb)
          end if
       end if
    end do
  end subroutine buffer_ghost_cells

  subroutine set_ghost_cells(mg, id)
    type(mg_2d_t), intent(inout) :: mg
    integer, intent(in)          :: id
    integer                      :: nb, nb_id, nb_rank

    do nb = 1, num_neighbors
       nb_id = mg%boxes(id)%neighbors(nb)

       if (nb_id > no_box) then
          ! There is a neighbor
          nb_rank    = mg%boxes(nb_id)%rank

          if (nb_rank == mg%my_rank) then
             call copy_from_nb(mg, mg%boxes(id), mg%boxes(nb_id), nb)
          else
             call fill_buffered_nb(mg, mg%boxes(id), nb_rank, nb)
          end if
       end if
       ! else if (nb_id == af_no_box) then
       !    ! Refinement boundary
       !    call subr_rb(boxes, id, nb, iv)
       ! else
       !    ! Physical boundary
       !    call subr_bc(boxes(id), nb, iv, bc_type)
       !    call bc_to_gc(boxes(id), nb, iv, bc_type)

    end do
  end subroutine set_ghost_cells

  subroutine copy_from_nb(mg, box, box_nb, nb)
    type(mg_2d_t), intent(inout)  :: mg
    type(box_2d_t), intent(inout) :: box
    type(box_2d_t), intent(in)    :: box_nb
    integer, intent(in)           :: nb
    real(dp)                      :: gc(mg%box_size)

    call box_gc_from_neighbor(box_nb, nb, mg%box_size, gc)
    call box_set_gc(box, nb, mg%box_size, gc)
  end subroutine copy_from_nb

  subroutine buffer_for_nb(mg, box, nb_id, nb_rank, nb)
    use mpi
    type(mg_2d_t), intent(inout)  :: mg
    type(box_2d_t), intent(inout) :: box
    integer, intent(in)           :: nb_id
    integer, intent(in)           :: nb_rank
    integer, intent(in)           :: nb
    integer                       :: i

    i = mg%buf(nb_rank)%i_send
    call box_gc_for_neighbor(box, nb, mg%box_size, &
         mg%buf(nb_rank)%send(i+1:i+mg%box_size))

    ! Later the buffer is sorted, using the fact that loops go from low to high
    ! box id, and we fill ghost cells according to the neighbor order
    i = mg%buf(nb_rank)%i_ix
    mg%buf(nb_rank)%ix(i+1) = num_neighbors * nb_id + neighb_rev(nb)

    mg%buf(nb_rank)%i_send = mg%buf(nb_rank)%i_send + mg%box_size
    mg%buf(nb_rank)%i_ix   = mg%buf(nb_rank)%i_ix + 1
  end subroutine buffer_for_nb

  subroutine fill_buffered_nb(mg, box, nb_rank, nb)
    use mpi
    type(mg_2d_t), intent(inout)  :: mg
    type(box_2d_t), intent(inout) :: box
    integer, intent(in)           :: nb_rank
    integer, intent(in)           :: nb
    integer                       :: i

    i = mg%buf(nb_rank)%i_recv
    call box_set_gc(box, nb, mg%box_size, &
         mg%buf(nb_rank)%recv(i+1:i+mg%box_size))
    mg%buf(nb_rank)%i_recv = mg%buf(nb_rank)%i_recv + mg%box_size

  end subroutine fill_buffered_nb

  subroutine box_gc_for_neighbor(box, nb, nc, gc)
    type(box_2d_t), intent(in) :: box
    integer, intent(in)        :: nb, nc
    real(dp), intent(out)      :: gc(nc)

    select case (nb)
    case (neighb_lowx)
       gc = box%cc(1, 1:nc, i_phi)
    case (neighb_highx)
       gc = box%cc(nc, 1:nc, i_phi)
    case (neighb_lowy)
       gc = box%cc(1:nc, 1, i_phi)
    case (neighb_highy)
       gc =box%cc(1:nc, nc, i_phi)
    end select
  end subroutine box_gc_for_neighbor

  subroutine box_gc_from_neighbor(box_nb, nb, nc, gc)
    type(box_2d_t), intent(in) :: box_nb
    integer, intent(in)        :: nb, nc
    real(dp), intent(out)      :: gc(nc)

    select case (nb)
    case (neighb_lowx)
       gc = box_nb%cc(nc, 1:nc, i_phi)
    case (neighb_highx)
       gc = box_nb%cc(1, 1:nc, i_phi)
    case (neighb_lowy)
       gc = box_nb%cc(1:nc, nc, i_phi)
    case (neighb_highy)
       gc = box_nb%cc(1:nc, 1, i_phi)
    end select
  end subroutine box_gc_from_neighbor

  subroutine box_set_gc(box, nb, nc, gc)
    type(box_2d_t), intent(inout) :: box
    integer, intent(in)           :: nb, nc
    real(dp), intent(in)          :: gc(nc)

    select case (nb)
    case (neighb_lowx)
       box%cc(0, 1:nc, i_phi) = gc
    case (neighb_highx)
       box%cc(nc+1, 1:nc, i_phi) = gc
    case (neighb_lowy)
       box%cc(1:nc, 0, i_phi) = gc
    case (neighb_highy)
       box%cc(1:nc, nc+1, i_phi) = gc
    end select
  end subroutine box_set_gc

end module m_ghost_cells