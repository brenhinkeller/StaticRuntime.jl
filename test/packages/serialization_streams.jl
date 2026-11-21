# Streams that Julia wrote, read by a program: the types that the program has are registered (`add_deserialize_types!`), and what it reads is compared with what Julia reads. Run by `serialization.jl`, in a process of its own: what is
# registered is the registry of the process, and the types of all of these are the types that every `deserialize` of it is made over.

using Test, Serialization, StaticRuntime
include(joinpath(@__DIR__, "..", "helpers.jl"))

struct SerRead; a::Int; b::Float64; end
struct SerReadNested; p::SerRead; s::String; v::Vector{Int}; t::Tuple{Int,String}; end

# (a stream that Julia wrote: it is a constant of the program, which has only what the registration says of the types)
const SER_BYTES = Vector{UInt8}[] # (a vector that is indexed: see the note on constant `Dict`s in the manual)
function ser_bytes(name, x)
    io = IOBuffer(); serialize(io, x)
    push!(SER_BYTES, take!(io))
    StaticRuntime.add_deserialize_types!(typeof(x))
    return name
end
const SER_FROM_JULIA = [
    "an integer" => 300, "a float" => 2.5, "a boolean" => true, "a string" => "hello", "a long string" => "a string that is longer than seven characters",
    "a Vector{Float64}" => [1.0, 2.0, 3.5], "a Matrix" => [1 2; 3 4], "a Vector{String}" => ["a", "bcdefghij", "a"], "a Vector{Bool}" => [true, false, true, true],
    "a struct" => SerRead(7, 2.5), "structs that hold structs" => SerReadNested(SerRead(3, 4.0), "s", [1, 2], (5, "t")), "a Vector of structs" => [SerRead(1, 2.0), SerRead(3, 4.0)],
    "a Dict" => Dict(1 => 2.0, 3 => 4.0), "a Dict of vectors" => Dict("a" => [1], "b" => [2, 3]), "a tuple" => (1, 2.5), "a Set" => Set([1, 2, 3]), "a range" => 1:5,
    "a Complex" => complex(1.0, 2.0), "a NamedTuple" => (a = 1, b = 2.0), "a Vector{Union{Int,Nothing}}" => Union{Int,Nothing}[1, nothing, 3],
    "a character" => 'x', "a UInt8 array" => UInt8[1, 2, 3], "a large integer" => 3000000000,
]
for (name, x) in SER_FROM_JULIA; ser_bytes(name, x); end
StaticRuntime.add_deserialize_types!(Vector{Any}, Int, String, Float64) # (the types of what a `Vector{Any}` holds are not known: they are registered)
ser_bytes("a Vector{Any}", Any[1, "x", 2.5])

# (the program reads the bytes of the name)
# (as the type that it is: a read that is not asserted gives a value of any of the types that the program has, and printing it is a call over all of them)
reads(i::Int, ::Type{T}) where {T} = () -> (r = deserialize(IOBuffer(copy(SER_BYTES[i])))::T; println(r); 0)


@testset "streams that Julia wrote" begin
    check_cases([name => reads(i, typeof(x)) for (i, (name, x)) in enumerate(SER_FROM_JULIA)])
    check_cases(["a Vector{Any}" => reads(length(SER_BYTES), Vector{Any})])
end

@testset "a stream that has a type that the program does not have" begin
    # (the program has `Float64`, among the types above, and is given a `Float32`)
    bytes = (io = IOBuffer(); serialize(io, Float32(2.5)); take!(io))
    exe = compile_main(() -> (r = deserialize(IOBuffer(copy(bytes)))::Float64; println(r); 0))
    err = IOBuffer()
    proc = run(pipeline(ignorestatus(`$exe`); stdout = devnull, stderr = err))
    @test !success(proc)
    @test occursin("not of a type that the program has", String(take!(err)))
end
