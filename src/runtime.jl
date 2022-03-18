make_workqueue() = SingleReaderDualBag{Any}()
# It'd be nice to use `SingleReaderDualBag{OpaqueClosure{Tuple{},Nothing}}()`.  However,
# user-defined async finalizer may always throw.

const QUEUE = Ref{Union{typeof(make_workqueue()),Nothing}}()

"""
    AsyncFinalizers.register(finalizer_factory, object)

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
function AsyncFinalizers.register(finalizer_factory::F, object::T) where {F,T}
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

function run_finalizers(queue; reset_sticky::Bool = false)
    works = eltype(queue)[]
    while true
        takemanyto!(works, queue)
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
        empty!(works)
    end
end

function _run_finalizers(queue; options...)
    try
        run_finalizers(queue; options...)
    catch err
        # TODO: improve error recovery
        @error(
            "FATAL: finalizer executor shutting down",
            exception = (err, catch_backtrace())
        )
        if QUEUE[] === queue
            QUEUE[] = nothing
        end
        rethrow()
    end
end

const EXECUTOR = Ref{Union{Task,Nothing}}()

"""
    reinit()

(Re-)initialize the task executing the finalizer.
"""
function reinit()
    QUEUE[] = queue = make_workqueue()
    EXECUTOR[] = Threads.@spawn _run_finalizers(queue; reset_sticky = true)
end

function onexit()
    QUEUE[] = nothing
    EXECUTOR[] = nothing
end
