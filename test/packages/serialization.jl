# Serialization: `serialize` of values whose types are known when compiling writes the bytes that Julia writes (they are printed, and compared with Julia's): numbers, strings, symbols, tuples, arrays (of numbers,
# of strings, of arrays, of a union, of `Any`), dictionaries and sets, structs, objects that refer to themselves, types as the parameters of what is written, ranges and `BigInt`.
# (Julia's `deserialize` finds the module of a type by its name, from `Main`; the module of this file, in `runtests.jl`, is made with `Module` and is not one of its names)
isdefined(Main, nameof(@__MODULE__)) || Core.eval(Main, :(const $(nameof(@__MODULE__)) = $(@__MODULE__)))

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

## deserialize
#
# The types that a program can read are those that it writes (it finds them: what a type holds too) and those that are registered (`add_deserialize_types!`: for a stream that another program wrote). A value is read as the code of its type says,
# and the output is compared with what Julia reads.

struct SerRead; a::Int; b::Float64; end
struct SerReadNested; p::SerRead; s::String; v::Vector{Int}; t::Tuple{Int,String}; end
mutable struct SerReadNode; x::Int; next::Union{Nothing,SerReadNode}; end

# (in the program: write and read)
roundtrip(x) = (io = IOBuffer(); serialize(io, x); seekstart(io); deserialize(io))

@testset "Serialization" begin
    @testset "Serialize" begin
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

    @testset "Deserialize" begin
        # (`SerReadNode` refers to itself, and its `show` can not be compiled: it is left out of the calls over the types of the program, and compiling warns of that, which is not what is tested)
        Logging.with_logger(Logging.NullLogger()) do
        check_cases([
            "an integer"                  => () -> (println(roundtrip(opaque(42))); 0),
            "a Vector{Float64}"           => () -> (println(roundtrip([opaque(1.0), 2.0])); 0),
            "a struct and a string"       => () -> (r = roundtrip(SerRead(opaque(1), 2.5))::SerRead; println(r.a, " ", r.b); println(roundtrip("a long string " * string(opaque(1)))); 0),
            "two types, one write each"   => () -> (a = roundtrip(SerRead(opaque(1), 2.5))::SerRead; b = roundtrip([opaque(3), 4])::Vector{Int}; println(a.a, " ", a.b); println(b); 0),
            "structs that hold structs"   => () -> (r = roundtrip(SerReadNested(SerRead(opaque(1), 2.0), "s", [1, 2], (3, "t")))::SerReadNested; println(r.p.a, " ", r.p.b, " ", r.s, " ", r.v, " ", r.t); 0),
            "an object that refers to itself" => () -> (m = SerReadNode(opaque(1), nothing); m.next = m; r = roundtrip(m)::SerReadNode; println(nameof(typeof(r))); println(r.x, " ", r.next === r); 0),
            "a Dict"                      => () -> (println(roundtrip(Dict(opaque(1) => "x", 2 => "y"))); 0),
            "an array that is shared"     => () -> (a = [opaque(1)]; r = roundtrip((a, a)); println(r[1] === r[2]); 0),
            "the type that it is given"   => () -> (r = roundtrip([opaque(1.0), 2.0])::Vector{Float64}; println(sum(r)); 0),
        ])
        end
        # Streams that Julia wrote, read by a program: the types that the program has are registered (`add_deserialize_types!`), and what it reads is compared with what Julia read.
        # What is registered is the registry of the process, and the types of all of these are the types that every `deserialize` of it is made over: so this is in a process of its own
        # (the code is written to a file, and run).
        @testset "streams that Julia wrote, and a type that the program does not have" begin
            streams_program = quote
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
            end
            mktempdir() do dir
                script = joinpath(dir, "serialization_streams.jl")
                write(script, "using Test, Serialization, StaticRuntime\ninclude($(repr(joinpath(@__DIR__, "..", "helpers.jl"))))\n", string(streams_program))
                proc = run(ignorestatus(`$(Base.julia_cmd()) --project=$(Base.active_project()) $script`))
                @test success(proc)
            end
        end
    end

    @testset "A program that does not read has no reader, and one that does not write or read has nothing of this" begin
        writes_only = compile_main(() -> (io = IOBuffer(); serialize(io, [opaque(1.0), 2.0]); length(take!(io))))
        reads_too = compile_main(() -> (println(roundtrip([opaque(1.0), 2.0])); 0))
        @test !occursin("the program does not have", String(read(writes_only)))
        @test !occursin("deserialize:", String(read(writes_only)))
        @test occursin("deserialize:", String(read(reads_too)))
        # (a program that has no use of Serialization is the one that is made without the extension: the executables are the same)
        # (a function of `Main` in both: the name of the module that a function is in is in the binary)
        program = "zero_cost_program() = (s = 0; for i in 1:(Base.inferencebarrier(10)::Int); s += i * i; end; println(s); 0)"
        Core.eval(Main, Meta.parse(program))
        here = read(compile_main(Main.zero_cost_program))
        there = mktemp() do path, io
            close(io)
            code = "using StaticRuntime, Libdl, LLVM; include(joinpath(\"$(joinpath(@__DIR__, ".."))\", \"helpers.jl\")); $program; write(\"$path\", read(compile_main(zero_cost_program)))"
            run(`$(Base.julia_cmd()) --project=$(Base.active_project()) -e $code`)
            read(path)
        end
        # (not the same to the byte: the names of the globals of a program have the addresses of the objects in them, and the number in the name of its function counts the programs that were made. What the extension would add is code, kilobytes of it)
        @test abs(length(here) - length(there)) < 128
    end
end
