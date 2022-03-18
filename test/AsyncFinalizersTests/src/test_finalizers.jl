module TestFinalizers

using Test
using AsyncFinalizers
using AsyncFinalizers.Internal: fallback_finalize

using ..Utils: check_executor, outlined, collect_garbage

function test_simple()
    collect_garbage()
end

function test_once()
    ncalls = Threads.Atomic{Int}(0)
    function async_finalizer(_)
        Threads.atomic_add!(ncalls, 1)
    end
    @testset "Initial collect_garbage" begin
        collect_garbage(; async_finalizer = async_finalizer)
    end
    @testset for trial in 1:5
        collect_garbage()
    end
    @test ncalls[] == 1
end

function test_lock()
    check_executor()
    a = 0
    guard = ReentrantLock()
    outlined() do
        local r = Ref(0)
        AsyncFinalizers.onfinalize(r) do _
            function ()
                lock(guard) do
                    a = 1
                end
            end
        end
    end
    GC.gc()

    for _ in 1:1000
        lock(guard) do
            a == 1
        end && break
        sleep(0.01)
    end

    @test a == 1
end

function test_fallback()
    counter = Ref(0)
    f() = counter[] += 1
    T = Int
    @test_logs (:warn, r"queue not initalized") wait(fallback_finalize(f, T)::Task)
    @test counter[] == 1
end

end  # module
