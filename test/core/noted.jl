# Types that the program notes, for code that reads a value of any of them (`note_type` and `call_over_noted`, `src/inference/noted.jl`): what `deserialize` is made of. The code that makes the values says what types it has, the code that reads
# them is made over those, and a program that does not use it has nothing of it.

using StaticRuntime: note_type, call_over_noted, add_noted_types!

# a reader over the types of `U`: a number of the type that the `n`th of them is
@generated function noted_pick(::Val{U}, n::Int) where {U}
    chain = :(error("not a type that there is"))
    for (i, T) in reverse(collect(enumerate(sort!(Base.uniontypes(U); by = string))))
        chain = :(n == $i ? $(T <: Number ? :($T(10 * $i)) : :("text")) : $chain)
    end
    return chain
end
noted_note_types() = (note_type(:picked, Int); note_type(:picked, Float64); note_type(:picked, String); nothing)
noted_second() = (v = call_over_noted(:picked, noted_pick, opaque(2)); println(typeof(v), " ", v); 0) # (`Float64`, `Int`, `String`: sorted by name)

@testset "Noted types" begin
    # types noted anywhere in the program (after the read, too) are what the read is made over
    out = compiled_stdout(() -> (noted_note_types(); noted_second()))
    @test startswith(out, "Int64 20")
    out = compiled_stdout(() -> (noted_second(); noted_note_types(); 0))
    @test startswith(out, "Int64 20")
    # a type that is registered is one too
    add_noted_types!(:picked_registered, Int8)
    out = compiled_stdout(() -> (v = call_over_noted(:picked_registered, noted_pick, opaque(1)); println(typeof(v), " ", v); 0))
    @test startswith(out, "Int8 10")
    # nothing is left in a program that notes types and does not read them: it is the program that does not note them
    plain = filesize(compile_main(() -> opaque(7)))
    @test filesize(compile_main(() -> (noted_note_types(); opaque(7)))) == plain
end
