# AsyncFinalizers

AsyncFinalizers.jl extends `finalizer` for

* Allowing executing arbitrary code, including I/O, upon garbage collection of a given
  object.

* Safe and unsafe APIs for avoiding escaping and thus "resurrecting" the object that would
  be collected otherwise.

## API

* `AsyncFinalizers.register`: like `finalizer` but allows I/O
* `AsyncFinalizers.unsafe_unwrap`: unwrap the `shim` wrapper (see below)

## Example

```julia
julia> using AsyncFinalizers

julia> mutable struct RefInt
           value::Int
       end

julia> object = RefInt(42);

julia> AsyncFinalizers.register(object) do shim
           # Unpack `shim` of the finalized `object`.  I/O is not allowed here.
           value = shim.value
           # Return a thunk:
           return function ()
               # Arbitrary I/O is possible here:
               println("RefInt(", value, ") is finalized")
           end
       end

julia> ref = nothing

julia> GC.gc(); sleep(0.1)
RefInt(42) is finalized
```

Note that the callback passed to `AsyncFinalizers.register` receives a `shim` wrapper and
not the original `object` itself.  To get the original object wrapped in `shim`, use
`AsyncFinalizers.unsafe_unwrap`.
