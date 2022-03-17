using Test
using AsyncFinalizers

# Since the world age inside the task is determined by the time when the task is started in
# old Julia, wait a bit for it to start.
sleep(0.01)

include("utils.jl")

CHAOS_COUNTER = Threads.Atomic{Int}(0)

ASYNCFINALIZERSTESTS_CHAOS = get(ENV, "ASYNCFINALIZERSTESTS_CHAOS", "takemanyto")
if ASYNCFINALIZERSTESTS_CHAOS == "takemanyto"
    function AsyncFinalizers.Internal.chaos_takemanyto()
        if Threads.atomic_add!(CHAOS_COUNTER, 1) == 1
            error("!!! CHAOS !!!")
        end
    end
    wait_recovery() = nothing
elseif ASYNCFINALIZERSTESTS_CHAOS == "run_finalizers"
    function AsyncFinalizers.Internal.chaos_run_finalizers()
        # FIXME: a yield point here breaks the test
        # yield()
        if Threads.atomic_add!(CHAOS_COUNTER, 1) == 1
            error("!!! CHAOS !!!")
        end
    end
    CHAOS_RECOVERED = Channel{Nothing}(1)
    function AsyncFinalizers.Internal.queue_reset_done()
        put!(CHAOS_RECOVERED, nothing)
    end
    function wait_recovery()
        if CHAOS_COUNTER[] == 2
            take!(CHAOS_RECOVERED)
        end
    end
else
    error("Unknown target: ASYNCFINALIZERSTESTS_CHAOS = ", ASYNCFINALIZERSTESTS_CHAOS)
end
@info "Testing: ASYNCFINALIZERSTESTS_CHAOS = $ASYNCFINALIZERSTESTS_CHAOS"

AsyncFinalizers.Internal.reinit()

nfinalizers = 5
FINALIZER_CALLED = zeros(Int, nfinalizers)

for i in 1:nfinalizers
    @info "Testing $i-th finalizer"
    function async_finalizer(_)
        FINALIZER_CALLED[i] += 1
    end
    Utils.collect_garbage(; async_finalizer = async_finalizer)
    wait_recovery()
end

@test FINALIZER_CALLED == ones(Int, nfinalizers)
