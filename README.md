# AsyncFinalizers

[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://juliaconcurrent.github.io/AsyncFinalizers.jl/dev)
[![CI](https://github.com/JuliaConcurrent/AsyncFinalizers.jl/actions/workflows/test.yml/badge.svg)](https://github.com/JuliaConcurrent/AsyncFinalizers.jl/actions/workflows/test.yml)

AsyncFinalizers.jl extends `finalizer` for

* Allowing executing arbitrary code, including I/O, upon garbage collection of a given
  object.

* Safe and unsafe APIs for avoiding escaping and thus "resurrecting" the object that would
  be collected otherwise.

For more information, see the
[documentation](https://juliaconcurrent.github.io/AsyncFinalizers.jl/dev).

For how it works internally, see [Implementation strategy](#implementation-strategy).

## API

* `AsyncFinalizers.onfinalize`: like `finalizer` but allows I/O
* `AsyncFinalizers.unsafe_unwrap`: unwrap the `shim` wrapper (see below)

## Example

```julia
julia> using AsyncFinalizers

julia> mutable struct RefInt
           value::Int
       end

julia> object = RefInt(42);

julia> AsyncFinalizers.onfinalize(object) do shim
           # Unpack `shim` of the finalized `object`.  I/O is not allowed here.
           value = shim.value
           # Return a thunk:
           return function ()
               # Arbitrary I/O is possible here:
               println("RefInt(", value, ") is finalized")
           end
       end;

julia> object = nothing

julia> GC.gc(); sleep(0.1)
RefInt(42) is finalized
```

Note that the callback passed to `AsyncFinalizers.onfinalize` receives a `shim` wrapper and
not the original `object` itself.  To get the original object wrapped in `shim`, use
`AsyncFinalizers.unsafe_unwrap`.

## Implementation strategy

AsyncFinalizers.jl works internally by a background worker task that processes queued async
finalizers (returned as thunks from the "on-finalize" callback registered using
`AsyncFinalizers.onfinalize`) and a queue with _lock-free `put!`_ called from the standard
finalizer (the callback passed to `Base.finalize`).  Since `put!` is [lock-free in the
"strict" sense](https://en.wikipedia.org/wiki/Non-blocking_algorithm) (modulo GC), `put!`
called in the standard finalizer can _always_ eventually make forward progress independent
of the state of the worker task at which it encounters the GC safepoint.
