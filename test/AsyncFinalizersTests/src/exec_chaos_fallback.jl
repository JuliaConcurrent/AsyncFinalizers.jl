using Test
using AsyncFinalizers

include("utils.jl")

function AsyncFinalizers.Internal.chaos_run_finalizers()
    error("!!! CHAOS !!!")
end

FALLBACK_DONE = Channel{Nothing}(1)

function AsyncFinalizers.Internal.queue_fallback_done()
    put!(FALLBACK_DONE, nothing)
end


AsyncFinalizers.Internal.reinit(; nresets = 3)

# Run an async finalizer to hit the fallback code path:
Utils.outlined() do
    AsyncFinalizers.onfinalize(Ref(0)) do _
        function () end
    end
    return
end
GC.gc()
take!(FALLBACK_DONE)

nfinalizers = 5
FINALIZER_CALLED = zeros(Int, nfinalizers)

for i in 1:nfinalizers
    @info "Testing $i-th finalizer"
    function async_finalizer(_)
        FINALIZER_CALLED[i] += 1
    end
    Utils.collect_garbage(; async_finalizer = async_finalizer, check_executor = false)
end

@test FINALIZER_CALLED == ones(Int, nfinalizers)
