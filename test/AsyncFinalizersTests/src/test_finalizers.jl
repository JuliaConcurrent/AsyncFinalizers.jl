module TestFinalizers

using Test
using AsyncFinalizers
using AsyncFinalizers.Internal: fallback_finalize

using ..Utils: check_executor, outlined

function test_simple()
    check_executor()
    a = Threads.Atomic{Int}(0)
    b = Threads.Atomic{Int}(0)
    outlined() do
        local r = Ref(0)
        AsyncFinalizers.register(r) do _
            a[] = 1
            function ()
                b[] = 1
            end
        end
    end
    GC.gc()

    @test a[] == 1

    for _ in 1:1000
        b[] == 1 && break
        sleep(0.01)
    end

    @test b[] == 1
end

function test_lock()
    check_executor()
    a = 0
    guard = ReentrantLock()
    outlined() do
        local r = Ref(0)
        AsyncFinalizers.register(r) do _
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
