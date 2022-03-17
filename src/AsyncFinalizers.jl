baremodule AsyncFinalizers

function register end
function unsafe_unwrap end

module Internal

using Base.Threads: atomic_cas!, atomic_or!, atomic_fence

using ..AsyncFinalizers: AsyncFinalizers

if isfile(joinpath(@__DIR__, "config.jl"))
    include("config.jl")
else
    include("default-config.jl")
end

include("utils.jl")
include("bags.jl")
include("shims.jl")
include("runtime.jl")

function __init__()
    reinit()
    atexit(onexit)
end

# Use README as the docstring of the module:
@doc let path = joinpath(dirname(@__DIR__), "README.md")
    include_dependency(path)
    replace(read(path, String), r"^```julia"m => "```jldoctest README")
end AsyncFinalizers

end  # module Internal

end  # baremodule AsyncFinalizers
