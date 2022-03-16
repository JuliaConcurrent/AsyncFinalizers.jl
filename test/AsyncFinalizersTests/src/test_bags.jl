module TestBags

using Test
using AsyncFinalizers.Internal: @record, SingleReaderDualBag, takemany!, takemanyto!

function test_serial()
    bag = SingleReaderDualBag{Any}()
    put!(bag, 1)
    put!(bag, 2)
    put!(bag, 3)
    items = takemany!(bag)
    @test sort!(items) == 1:3
end

function check_concurrent(ntasks; nitems = 10000)
    bag = SingleReaderDualBag{Int}()
    items = eltype(bag)[]
    haserror = Threads.Atomic{Bool}(false)
    @record(:check_concurrent_sync_begin)
    @sync begin
        for tid in 1:ntasks
            Threads.@spawn try
                @record(:check_concurrent_writer_begin, tid)
                for i in tid:ntasks:nitems
                    put!(bag, i)
                    haserror[] && break
                end
                @record(:check_concurrent_writer_end, tid)
            catch err
                haserror[] = true
                @error(
                    "check_concurrent: writer $tid failed",
                    exception = (err, catch_backtrace())
                )
            end
        end
        takemanyto!(items, bag)
        while length(items) < nitems
            @record(:check_concurrent_polling, ntaken = length(items))
            takemanyto!(items, bag)
            haserror[] && break
        end
    end
    @record(:check_concurrent_sync_end)
    @test sort!(items) == 1:nitems
end

function test_concurrent()
    @testset for ntasks in unique!([
        1,
        Threads.nthreads(),
        cld(Threads.nthreads(), 2),
        2 * Threads.nthreads(),
    ])
        check_concurrent(ntasks)
    end
end

end  # module
