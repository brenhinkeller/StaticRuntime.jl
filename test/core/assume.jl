# Types that are stated (`@assume`, `@assume_field`: `src/inference/assume.jl`): the call or the field is the one of the code, inferred as it is, and what it gives is of the type that is stated, where inference
# finds a wider one; where the code gives another type, the program stops with a type error.

struct AInfo; x::Int; end
struct ABag; v::Any; end
@noinline ainfo(d::Dict{Symbol,Any}, k::Symbol) = d[k]
@noinline aliar(d::Dict{Symbol,Any}, k::Symbol) = d[k]
@noinline abag(x::Int) = ABag(AInfo(x))
@noinline abag_liar(x::Int) = ABag(Base.inferencebarrier(x + 0.5))

# (a package states these where it is initialized: `__init__`)
StaticRuntime.@assume ainfo(::Dict{Symbol,Any}, ::Symbol)::AInfo
StaticRuntime.@assume aliar(::Dict{Symbol,Any}, ::Symbol)::AInfo
StaticRuntime.@assume_field ABag.v::AInfo

# a field that holds what the objects that are made when compiling hold (`@assume_field_embedded`): a function that stores a value of a type that is not known in the field (a `@nospecialize` parameter) does not count
mutable struct EBox; v::Any; end
const EB = EBox(AInfo(7))
eget(x::AInfo) = x.x
eget(x::Int) = x
@noinline eset!(b::EBox, @nospecialize(x)) = (b.v = x; nothing)
StaticRuntime.@assume_field_embedded EBox.v

@testset "Types that are @assumed" begin
    @testset "the type of a call" begin
        check_cases(["a call of a method that gives Any" => () -> (d = Dict{Symbol,Any}(:a => AInfo(opaque(3))); ainfo(d, :a).x + opaque(0))]; batch = false)
    end
    @testset "the type of a field" begin
        check_cases(["a field of the type Any" => () -> (abag(opaque(4)).v.x)]; batch = false)
    end
    @testset "the type of what is embedded" begin
        check_cases(["a store of a value of a type that is not known" => () -> (eset!(EBox(AInfo(1)), Base.inferencebarrier(AInfo(opaque(2)))); eget(EB.v) + opaque(0))]; batch = false)
    end
    @testset "a macro with the wrong form is an error" begin
        @test_throws ArgumentError @macroexpand StaticRuntime.@assume_field_embedded EBox
        @test_throws ArgumentError StaticRuntime.assume_field_embedded!(EBox, :nothere)
        @test_throws ArgumentError @macroexpand StaticRuntime.@assume ainfo
        @test_throws ArgumentError @macroexpand StaticRuntime.@assume_field ABag::AInfo
        @test_throws ArgumentError StaticRuntime.assume_return!(Int, Int)
        @test_throws ArgumentError StaticRuntime.assume_field!(ABag, :nothere, Int)
    end
end

# what is stated is checked: a program in which the call, or the field, has another type stops with a type error, and does not go on as if it had the type
@eval assume_wrong_call(argc::Int, argv::Ptr{Ptr{UInt8}}) = (d = Dict{Symbol,Any}(:a => opaque(5) + 0.5); println(aliar(d, :a).x); 0)
@eval assume_wrong_field(argc::Int, argv::Ptr{Ptr{UInt8}}) = (println(abag_liar(opaque(1)).v.x); 0)
@eval assume_wrong_embedded(argc::Int, argv::Ptr{Ptr{UInt8}}) = (eset!(EB, Base.inferencebarrier(opaque(1) + 0.5)); println(eget(EB.v)); 0)
@testset "What is @assumed is checked" begin
    @test_throws ProcessFailedException run_main(assume_wrong_embedded)
    @test_throws ProcessFailedException run_main(assume_wrong_call)
    @test_throws ProcessFailedException run_main(assume_wrong_field)
end
