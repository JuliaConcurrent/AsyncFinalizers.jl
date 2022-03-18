# A hopefully correct implementation of "non-blocking unordered single-reader channel."
#
# Important requirements:
# * Lock-free (in fact wait-free) and yield-free on the writer side (so that it can be used
#   inside the finalizer).
# * Reader can wait cooperatively (so that this can be used in a "background" task).
# * Implementable without atomics on GC-manged Julia object fields (for Julia < 1.7).
#
# The implementation can be simplified because of:
# * The insertion order is irrelevant.
# * Single-reader.

baremodule WorkerStates
using Base: UInt8
const Kind = UInt8
const ACTIVE = Kind(0)
const WAITING = Kind(1)
const NOTIFYING = Kind(2)
end  # baremodule WorkerStates

"""
    WriterState{T}

Let `w = state.writable[]` where `state::WriterState`.  The lowest bit ("index bit") of `w`
indicates 0-origin index of the writable buffer; i.e.,

    i = (w & 0b1) + 1
    state.buffers[i]

is writable (if locked; see blow). The other buffer, i.e.,

    j = ~(w & 0b1) + 1
    state.buffers[j]

is readable.  If the second bit ("lock bit") of `w` is set, `state.buffers[i]` is considered
locked.

The writer obtains the exclusive access by setting the lock bit while the reader obtains the
exclusive access by flipping the index bit.

This is loosely inspired by the left-right technique.
"""
struct WriterState{T}
    writable::Threads.Atomic{UInt32}
    buffers::NTuple{2,Vector{T}}
end

WriterState{T}() where {T} = WriterState{T}(Threads.Atomic{UInt32}(), (T[], T[]))

"""
    SingleReaderDualBag{T}()

"Non-blocking unordered single-reader channel."
"""
mutable struct SingleReaderDualBag{T}
    # TODO: Use a proper thread-local storage for `states`
    @const states::Vector{WriterState{T}}
    @const readerstate::Threads.Atomic{WorkerStates.Kind}
    waiter::Union{Task,Nothing}
end

function SingleReaderDualBag{T}() where {T}
    states = [WriterState{T}() for _ in 1:Threads.nthreads()]
    readerstate = Threads.Atomic{WorkerStates.Kind}(WorkerStates.ACTIVE)
    return SingleReaderDualBag{T}(states, readerstate, nothing)
end

Base.eltype(::Type{SingleReaderDualBag{T}}) where {T} = T

const LOCKBITMASK = UInt32(0b10)

"""
    Base.put!(bag::SingleReaderDualBag, x)

Insert `x` to `bag`.  Notify the reader if required.  This method is wait-free.  It also has
no yield points provided that `convert(eltype(bag), x)` does not yield.
"""
function Base.put!(bag::SingleReaderDualBag{T}, x) where {T}
    @record(:put_begin, bag, x, {yield = false})
    x = convert(T, x)

    @yield_unsafe let state, writable  # [^crucially_yield_unsafe]
        state = bag.states[Threads.threadid()]

        # Acquire a writable buffer
        writable = atomic_or!(state.writable, LOCKBITMASK)
        @assert iszero(writable & LOCKBITMASK)
        @assert writable in (0, 1)

        push!(state.buffers[writable+1], x)

        # Release the buffer
        state.writable[] = writable
    end

    atomic_fence()  # [^store_buffering_1]
    if bag.readerstate[] == WorkerStates.WAITING
        old = atomic_cas!(bag.readerstate, WorkerStates.WAITING, WorkerStates.NOTIFYING)
        if old == WorkerStates.WAITING
            @record(:put_schedule, bag, x, {yield = false})
            schedule(bag.waiter::Task)
        end
    end

    @record(:put_end, bag, x, {yield = false})
    return bag
end
# [^crucially_yield_unsafe]: According to the docstring, everything in this function except
# the `convert` call is yield-unsafe.  However, the explicit `@yield_unsafe` block is "much
# more" yield-unsafe since the yield must not exist inside this block for correctness even
# without the specification in the docstring.

function trytakemanyto!(output, bag::SingleReaderDualBag)
    took = false
    locked = false
    for state in bag.states
        # Acquire a readable buffer
        writable = state.writable[]
        local readable::Int = -1
        while true
            if iszero(writable & LOCKBITMASK)
                new = (writable + one(writable)) & one(writable)
                old = atomic_cas!(state.writable, writable, new)
                if old == writable
                    readable = writable
                    @goto acquired
                end
            else
                locked = true
                break
            end
        end
        continue
        @label acquired
        @assert readable in (0, 1)

        buffer = state.buffers[readable+1]
        isempty(buffer) && continue
        append!(output, buffer)
        empty!(buffer)
        took = true
    end
    return (; took = took, locked = locked)
end

"""
    takemanyto!(output, bag::SingleReaderDualBag)

Take one or many items from `bag` and `append!` them into `output`.

The items that has been `put!` into `bag` are taken out from the `bag` if it is non-empty.
Otherwise, it waits until at least one item is available.

This method is lock-free if `bag` is not empty.
"""
function takemanyto!(output, bag::SingleReaderDualBag)
    @record(:takemanyto_begin, bag)
    chaos_takemanyto()
    result = trytakemanyto!(output, bag)
    if result.took
        @record(:takemanyto_end, bag, waited = false)
        return result
    end

    bag.waiter = current_task()
    while true
        @record(:takemanyto_wait_trying, bag)
        @yield_unsafe begin
            bag.readerstate[] = WorkerStates.WAITING
            atomic_fence()  # [^store_buffering_1]
            result = trytakemanyto!(output, bag)
            if result.took
                old =
                    atomic_cas!(bag.readerstate, WorkerStates.WAITING, WorkerStates.ACTIVE)
                if old == WorkerStates.WAITING
                    # It is yield-safe once the state transition is successfully cancelled.
                    @record(:takemanyto_wait_cancelled, bag, success = true)
                    break
                end
                @record(:takemanyto_wait_cancelled, bag, success = false, {yield = false})
                # Otherwise, it means that the reader (this task) has failed to cancel the
                # state transition.  It has to "receive" the `schedule` by calling `wait()`
                # and then return immediately. [^failed_to_cancel].
            end
            @record(:takemanyto_wait_begin, bag, {yield = false})
        end
        wait()
        @record(:takemanyto_wait_end, bag)
        @assert bag.readerstate[] == WorkerStates.NOTIFYING
        bag.readerstate[] = WorkerStates.ACTIVE
        result.took && break  # [^failed_to_cancel]: if it had failed to cancel

        result = trytakemanyto!(output, bag)
        result.took && break
    end
    bag.waiter = nothing
    @record(:takemanyto_end, bag, waited = true)
    return result
end
# [^store_buffering_1]: These fences are used to avoid the cycle 2b -> 1a -> 1b -> 2a -> 2b
# where
# * Reader:
#   * 1a: `bag.readerstate[] = WorkerStates.WAITING`
#   * 1b: `trytakemanyto!(output, bag).took` is `false` (acquiring of state locks)
# * Writer:
#   * 2a: state lock release in `put!(bag, x)`
#   * 2b: `bag.readerstate[]` in `put!` is not `WAITING`
# i.e., the reader misses the insertion and writer misses the sleep state transition.
#
# The edges of the cycle are:
# * 2b -> 1a: reads-before, due to the value read in 2b
# * 1a -> 1b: sequenced-before
# * 1b -> 2a: reads-before, due to the value read in 1b
# * 2a -> 2b: sequenced-before
#
# Ref:
# https://github.com/JuliaLang/julia/pull/43418#discussion_r790206434

function takemany!(bag::SingleReaderDualBag{T}) where {T}
    output = T[]
    takemanyto!(output, bag)
    return output
end
