# Serialization: `serialize` of values whose types are known when compiling writes the bytes that Julia writes (they are printed, and compared with Julia's): numbers, strings, symbols, tuples, arrays (of numbers,
# of strings, of arrays, of a union, of `Any`), dictionaries and sets, structs, objects that refer to themselves, types as the parameters of what is written, ranges and `BigInt`.

struct SerPoint; a::Int; b::Float64; end
struct SerNested; p::SerPoint; s::String; v::Vector{Int}; end
mutable struct SerNode; x::Int; next::Union{Nothing,SerNode}; end

# (a module with a name that is long, as the symbols of its path are kept in the table of what was written, and are a back reference the second time)
module SerLongModuleName
    struct SerInner; a::Int; end
    struct SerOuter; i::SerInner; j::SerInner; end
end

# (the bytes that are written, which the program prints, and how many they are)
serialized(x) = (io = IOBuffer(); serialize(io, x); b = take!(io); println(b); length(b))

@testset "Serialization" begin
    check_cases([
        "Integers"                   => () -> serialized(opaque(300)),
        "Negative and large integers" => () -> serialized((-opaque(1), opaque(1000000), typemax(Int), UInt8(opaque(3)), Int8(-3))),
        "A Complex number"           => () -> serialized(complex(opaque(1.0), 2.0)),
        "A tuple of several types"   => () -> serialized((opaque(1), 2.5, "a", :sym, 'c', true, nothing)),
        "A long symbol"              => () -> serialized(:a_long_symbol_name),
        "A function"                 => () -> serialized((sin, opaque(5))),
        "A NamedTuple"               => () -> serialized((a = opaque(1), b = 2.0)),
        "A range"                    => () -> serialized(1:opaque(5)),
        "A BigInt"                   => () -> serialized(big(opaque(10))^30),
        "A SubString"                => () -> serialized(SubString(opaque("hello"), 2, 4)),
    ])
    check_cases([
        "Vector{Float64}"            => () -> serialized([opaque(1.0), 2.0]),
        "Matrix{Float64}"            => () -> serialized(opaque(1.0) .* ones(2, 3)),
        "Array{Float32,3}"           => () -> serialized(zeros(Float32, 2, 2, opaque(2))),
        "Vector{UInt8}"              => () -> serialized(UInt8[opaque(1), 2]),
        "Vector{String}"             => () -> serialized([opaque("a"), "bc"]),
        "Vector{Symbol}, repeated"   => () -> serialized([:a, :b, :a_long_symbol_name, :a_long_symbol_name]),
        "Vector{Vector{Int}}"        => () -> serialized([[opaque(1)], [2, 3]]),
        "Vector{Union{Int,Nothing}}" => () -> serialized(Union{Int,Nothing}[opaque(1), nothing]),
        "Vector{Any}"                => () -> serialized(Any[opaque(1), "a", 2.5]),
        "The same array twice"       => () -> (a = [opaque(1)]; serialized((a, a))),
        "A type as a value"          => () -> serialized(Vector{opaque(Int)}),
    ])
    check_cases([
        "A struct"                   => () -> serialized(SerPoint(opaque(1), 2.0)),
        "A struct with structs, strings and arrays" => () -> serialized(SerNested(SerPoint(opaque(1), 2.0), "s", [1, 2])),
        "Two of one type"            => () -> serialized([SerPoint(opaque(1), 2.0), SerPoint(3, 4.0)]),
        "An object that refers to itself" => () -> (m = SerNode(opaque(1), nothing); m.next = m; serialized(m)),
        "Types in a module of a long name" => () -> serialized(SerLongModuleName.SerOuter(SerLongModuleName.SerInner(opaque(1)), SerLongModuleName.SerInner(2))),
        "A Dict"                     => () -> serialized(Dict(opaque(1) => 2.0)),
        "A Dict of arrays"           => () -> serialized(Dict("a" => [opaque(1)], "b" => [2])),
        "A Set"                      => () -> serialized(Set([opaque(1)])),
    ])
end

## deserialize
#
# The types that a program can read are those that it writes (it finds them: what a type holds too) and those that are registered (`add_deserialize_types!`: for a stream that another program wrote). A value is read as the code of its type says,
# and the output is compared with what Julia reads.

struct SerRead; a::Int; b::Float64; end
struct SerReadNested; p::SerRead; s::String; v::Vector{Int}; t::Tuple{Int,String}; end
mutable struct SerReadNode; x::Int; next::Union{Nothing,SerReadNode}; end

# (in the program: write and read)
roundtrip(x) = (io = IOBuffer(); serialize(io, x); seekstart(io); deserialize(io))

@testset "deserialize" begin
    check_cases([
        "an integer"                  => () -> (println(roundtrip(opaque(42))); 0),
        "a Vector{Float64}"           => () -> (println(roundtrip([opaque(1.0), 2.0])); 0),
        "a struct and a string"       => () -> (println(roundtrip(SerRead(opaque(1), 2.5))); println(roundtrip("a long string " * string(opaque(1)))); 0),
        "two types, one write each"   => () -> (a = roundtrip(SerRead(opaque(1), 2.5)); b = roundtrip([opaque(3), 4]); println(a); println(b); 0),
        "structs that hold structs"   => () -> (println(roundtrip(SerReadNested(SerRead(opaque(1), 2.0), "s", [1, 2], (3, "t")))); 0),
        "an object that refers to itself" => () -> (m = SerReadNode(opaque(1), nothing); m.next = m; r = roundtrip(m); println(typeof(r)); println(r.x, " ", r.next === r); 0),
        "a Dict"                      => () -> (println(roundtrip(Dict(opaque(1) => "x", 2 => "y"))); 0),
        "an array that is shared"     => () -> (a = [opaque(1)]; r = roundtrip((a, a)); println(r[1] === r[2]); 0),
        "the type that it is given"   => () -> (r = roundtrip([opaque(1.0), 2.0])::Vector{Float64}; println(sum(r)); 0),
    ])
    # (the registered types are those of the whole process, so what is read from a stream that Julia wrote is in a process of its own: `serialization_streams.jl`)
    @testset "streams that Julia wrote, and a type that the program does not have" begin
        script = joinpath(@__DIR__, "serialization_streams.jl")
        proc = run(ignorestatus(`$(Base.julia_cmd()) --project=$(Base.active_project()) $script`))
        @test success(proc)
    end
end

@testset "A program that does not read has no reader, and one that does not write or read has nothing of this" begin
    writes_only = compile_main(() -> (io = IOBuffer(); serialize(io, [opaque(1.0), 2.0]); length(take!(io))))
    reads_too = compile_main(() -> (println(roundtrip([opaque(1.0), 2.0])); 0))
    @test !occursin("the program does not have", String(read(writes_only)))
    @test !occursin("deserialize:", String(read(writes_only)))
    @test occursin("deserialize:", String(read(reads_too)))
    # (a program that has no use of Serialization is the one that is made without the extension: the executables are the same)
    program = "() -> (s = 0; for i in 1:opaque(10); s += i * i; end; println(s); 0)"
    here = read(compile_main(include_string(@__MODULE__, program)))
    there = mktemp() do path, io
        close(io)
        code = "using StaticRuntime, Libdl, LLVM; include(joinpath(\"$(joinpath(@__DIR__, ".."))\", \"helpers.jl\")); write(\"$path\", read(compile_main($program)))"
        run(`$(Base.julia_cmd()) --project=$(Base.active_project()) -e $code`)
        read(path)
    end
    # (the name of the function of the program has a number that counts the programs that were made: `static_main_7`, `static_main_12`)
    function normalized_length(bytes)
        pattern = codeunits("static_main_")
        n, i = 0, 1
        while i <= length(bytes)
            if i + length(pattern) <= length(bytes) && view(bytes, i:(i + length(pattern) - 1)) == pattern
                n += length(pattern) + 1
                i += length(pattern)
                while i <= length(bytes) && UInt8('0') <= bytes[i] <= UInt8('9')
                    i += 1
                end
            else
                n += 1
                i += 1
            end
        end
        return n
    end
    @test normalized_length(here) == normalized_length(there)
end
