module Utils

using AsyncFinalizers

function outlined(f)
    @noinline wrapper() = f()
    wrapper()
end

function check_executor()
    @assert !istaskdone(AsyncFinalizers.Internal.EXECUTOR[])
end

end  # module
