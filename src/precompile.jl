# Precompilation: the first compilation of a session is most of its cost to the person who waits for it (about 20 s: the code of the compiler itself, which is Julia code that has to be compiled when it is first run), and it
# is the same code every time. Here a few small programs are compiled when this package is, so that the code that every compilation runs is in the compiled image of the package, and is not compiled again by each session.
#
# What is made here is a workload, as `PrecompileTools` calls it: the methods that it makes Julia compile are the ones that are kept. The programs are a few: the first for the code that all programs go through (output, the
# entry point, the runtime, the link), the second for what a program that has a collection and a loop adds, and three that need more than one pass (a list of values of the type `Any` and its `show`, a `Dict`, text). What goes wrong here is a warning, and not an error: a package that can't make its workload still loads, and is
# compiled when it is used.
#
# The workload is not run when `precompile_workload` is `false` in the preferences of this package (`using Preferences; set_preferences!(StaticRuntime, "precompile_workload" => false; force = true)`),
# which makes the compiling of the package itself shorter, for working on it.

using PrecompileTools: @setup_workload, @compile_workload

# (the programs are in a module of their own: a module that is made while a package is compiled can't have methods added to it by the code that follows)
# (with the arguments of C, `main(argc, argv)`: the entry point that `compile_executable(f)` makes for `f()` is a function in a module that it makes when it is called, which can't be done while a package is compiled)
module PrecompileWorkload
describe(x::Int) = x
describe(x::String) = length(x)
describe(x::Float64) = round(Int, x)
describe(x::Symbol) = length(string(x))
hello(argc::Int, argv::Ptr{Ptr{UInt8}}) = (println("hello ", sum(1:10)); 0)
collection(argc::Int, argv::Ptr{Ptr{UInt8}}) = (v = Int[]; for i in 1:5; push!(v, i * i); end; println(v, " ", length(string(v))); 0)
# (the programs that dispatch on values of the type `Any`, and show them, take more passes than the others: what they infer is kept by the keys of the passes that find them)
showing(argc::Int, argv::Ptr{Ptr{UInt8}}) = (println(Any[1, "a", 2.5, :s, nothing, 'c']); println(Dict(:a => 1, :b => 2.5)); 0)
dictionary(argc::Int, argv::Ptr{Ptr{UInt8}}) = (d = Dict{Symbol,Any}(:a => 1, :b => "x"); for (k, v) in d; println(k, " ", describe(v)); end; 0)
text(argc::Int, argv::Ptr{Ptr{UInt8}}) = (s = join(string.(1:5), ","); println(uppercase(s), " ", parse(Int, "42"), " ", split("a b c")); 0)
end

@setup_workload begin
    @compile_workload begin
        dir = mktempdir()
        try
            for program in (PrecompileWorkload.hello, PrecompileWorkload.collection, PrecompileWorkload.showing, PrecompileWorkload.dictionary, PrecompileWorkload.text)
                Base.invokelatest(compile_executable, program, (Int, Ptr{Ptr{UInt8}}), dir, string(nameof(program)))
            end
        catch err
            @warn "The precompile workload (`src/precompile.jl`) could not be compiled; the first compilation of a session will be slower" exception = (err, catch_backtrace())
        finally
            rm(dir; force = true, recursive = true)
        end
    end
end
