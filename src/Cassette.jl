__precompile__(false)

module Cassette

const MAX_ARGS = 50

include("utilities/metaprogramming.jl")
include("utilities/anonymous.jl")

include("contextual/contexts.jl")
include("contextual/metadata.jl")

include("overdub/reflection.jl")
include("overdub/execution.jl")

include("api/api.jl")

end # module
