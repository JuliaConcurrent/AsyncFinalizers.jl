struct WeakRefShim{T}
    ref::WeakRef
    WeakRefShim(obj::T) where {T} = new{T}(WeakRef(obj))
end

valueof(shim::WeakRefShim) = getfield(shim, :ref).value

@noinline error_finalized() =
    error("object to be finalized cannot be accessed in async finalizer")

"""
    AsyncFinalizers.unsafe_unwrap(shim) -> object

Unwrap a `shim` and obtain the original object. The user is responsible for ensuring that
`object` does not escape.

See [`AsyncFinalizers.onfinalize`](@ref)
"""
function AsyncFinalizers.unsafe_unwrap(shim::WeakRefShim{T}) where {T}
    obj = valueof(shim)
    if obj isa T
        return obj
    else
        error_finalized()
    end
end

function Base.getproperty(shim::WeakRefShim{T}, name::Symbol) where {T}
    obj = valueof(shim)
    if obj isa T
        return getproperty(obj, name)
    else
        error_finalized()
    end
end

function Base.getproperty(shim::WeakRefShim{T}, name::Symbol, order::Symbol) where {T}
    obj = valueof(shim)
    if obj isa T
        return getproperty(obj, name, order)
    else
        error_finalized()
    end
end

function Base.setproperty!(shim::WeakRefShim{T}, name::Symbol, x) where {T}
    obj = valueof(shim)
    if obj isa T
        return setproperty!(obj, name, x)
    else
        error_finalized()
    end
end

function Base.setproperty!(shim::WeakRefShim{T}, name::Symbol, x, order::Symbol) where {T}
    obj = valueof(shim)
    if obj isa T
        return setproperty!(obj, name, x, order)
    else
        error_finalized()
    end
end
