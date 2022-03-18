module Utils

using AsyncFinalizers
using Test

function outlined(f)
    @noinline wrapper() = f()
    wrapper()
end

function check_executor()
    @assert !istaskdone(AsyncFinalizers.Internal.EXECUTOR[])
end

return_nothing(_...) = nothing

@noinline function collect_garbage(;
    object = () -> Ref(0),
    destruct = return_nothing,
    async_finalizer = return_nothing,
    npolls = 1_000_000_000,
    check_executor::Bool = true,
)
    check_executor && (@__MODULE__).check_executor()
    phase1 = Threads.Atomic{Int}(0)
    phase2 = Threads.Atomic{Int}(0)
    outlined() do
        local obj = object()
        AsyncFinalizers.register(obj) do obj
            phase1[] = 1
            local y = destruct(obj)
            function ()
                phase2[] = 1
                async_finalizer(y)
            end
        end
        return
    end
    GC.gc()

    n = 0
    while phase1[] == 0
        GC.safepoint()
        yield()
        if (n += 1) > npolls
            error("too many pollings. finalizer not called?")
        end
    end
    @test phase1[] == 1

    n = 0
    while phase2[] == 0
        GC.safepoint()
        yield()
        if (n += 1) > npolls
            error("too many pollings. async finalizer not called?")
        end
    end
    @test phase2[] == 1
end

end  # module
