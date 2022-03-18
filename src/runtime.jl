make_workqueue() = SingleReaderDualBag{Any}()
# It'd be nice to use `SingleReaderDualBag{OpaqueClosure{Tuple{},Nothing}}()`.  However,
# user-defined async finalizer may always throw.

const QUEUE = Ref{Union{typeof(make_workqueue()),Nothing}}()

"""
    AsyncFinalizers.onfinalize(finalizer_factory, object)

Register asynchronous finalizer for an `object`.

The callback function `finalizer_factory` is a function with the following signature

    finalizer_factory(shim) -> async_finalizer

i.e., `finalizer_factory` is a function that takes `shim` and returns `async_finalizer`
where `shim` is an object that wraps the `object` and provides the same properties and
`async_finalizer` is `nothing` or a callable that does not take any argument.  The `shim` is
valid only until `finalizer_factory` returns and not inside `async_finalizer`.  As such,
`finalizer_factory` must destruct `shim` and only capture the fields required for
`async_finalizer`.

Use [`AsyncFinalizers.unsafe_unwrap`](@ref) to unwrap `shim` and obtain the original
`object`.  However, it is the user's responsibility to ensure that `async_finalizer` does
not capture `object`.

The code executed in `finalizer_factory` should be as minimal as possible.  In particular,
no I/O is allowed inside of `finalizer_factory`.
"""
function AsyncFinalizers.onfinalize(finalizer_factory::F, object::T) where {F,T}
    function wrapper(object::T)
        GC.@preserve object begin
            f = finalizer_factory(WeakRefShim(object))
        end
        if f !== nothing
            work = @static if isdefined(Base.Experimental, Symbol("@opaque"))
                Base.Experimental.@opaque () -> begin
                    f()
                    nothing
                end
            else
                f
            end
            queue = QUEUE[]
            if queue === nothing
                fallback_finalize(f, T)
            else
                put!(queue, work)
            end
        end
        return
    end
    finalizer(wrapper, object)
end

function fallback_finalize(f, T)
    Threads.@spawn begin
        @warn(
            "Async finalizer queue not initalized. Calling async finalizer in a new task.",
            object_type = T,
            maxlog = 3,
        )
        f()
    end
end

function run_finalizers(queue; reset_sticky::Bool = false, nfailures::Integer = 5)
    works = eltype(queue)[]
    nf = 0
    while true
        chaos_run_finalizers()
        try
            takemanyto!(works, queue)
        catch err
            @error(
                "FATAL: Unexpected failure in finalizer queue. Some finalizers may be lost.",
                exception = (err, catch_backtrace()),
                current_task(),
            )
            nf += 1
        end
        for f in works
            try
                @static if isdefined(Core, :OpaqueClosure)
                    if f isa Core.OpaqueClosure{Tuple{},Nothing}
                        f()
                    else
                        if f isa Core.OpaqueClosure
                            f()
                        else
                            Base.invokelatest(f)
                        end
                    end
                else
                    Base.invokelatest(f)
                end
            catch err
                @error "Error from async finalizer" exception = (err, catch_backtrace())
                # TODO: store some recent failures and let users query them
            end
            if reset_sticky
                # Just in case `f` runs `@async`:
                current_task().sticky = false
            end
        end
        # TODO: check error rate?
        nf < nfailures || return
        empty!(works)
    end
end

function run_supervisor(queue; nresets::Integer = 100, options...)
    nr = 0
    while true
        try
            run_finalizers(queue; options...)
        catch err
            @error(
                "FATAL: Error from async finalizer executor",
                exception = (err, catch_backtrace())
            )
        end
        nr += 1
        nr < nresets || break
        if QUEUE[] !== queue
            @error "FATAL: Detected another exeuctor. Unavble to recover." current_task()
            return
        end
        @error "FATAL: Too many failures. Resetting queue."
        QUEUE[] = queue = make_workqueue()
        queue_reset_done()
    end
    @error "FATAL: Too many failures in finalizer executor. Switching to fallback."
    if QUEUE[] === queue
        QUEUE[] = nothing
        queue_fallback_done()
    end
end

function _run_supervisor(queue; options...)
    try
        run_supervisor(queue; options...)
    catch err
        @error(
            "FATAL: Unexpected failure in finalizer executor supervisor",
            exception = (err, catch_backtrace())
        )
    end
end

const EXECUTOR = Ref{Union{Task,Nothing}}()

"""
    reinit()

(Re-)initialize the task executing the finalizer.
"""
function reinit(; options...)
    QUEUE[] = queue = make_workqueue()
    EXECUTOR[] = Threads.@spawn _run_supervisor(queue; reset_sticky = true, options...)
end

function onexit()
    QUEUE[] = nothing
    EXECUTOR[] = nothing
end
