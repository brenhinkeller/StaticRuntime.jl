# Future: `copy!` of arrays, sets and dictionaries (what the standard library defines for Julia 1.0's `copy!`) and the copy of a random number generator.

@testset "Future" begin
    check_cases([
        "copy! of an array"           => () -> (a = [opaque(1), 2, 3]; b = zeros(Int, 3); Future.copy!(b, a); b[1] + b[3]),
        "copy! of a set"              => () -> (a = Set([opaque(1), 2]); b = Set{Int}(); Future.copy!(b, a); length(b) + 10 * (1 in b)),
        "copy! of a dictionary"       => () -> (a = Dict(opaque(1) => 2, 3 => 4); b = Dict{Int,Int}(); Future.copy!(b, a); b[1] + b[3]),
        "copy! of an empty array"     => () -> (a = Int[]; b = [opaque(1), 2]; Future.copy!(b, a); length(b)),
        "copy of a MersenneTwister"   => () -> (a = Random.MersenneTwister(opaque(1)); b = copy(a); Int(rand(a, 1:100) == rand(b, 1:100))),
    ])
end
