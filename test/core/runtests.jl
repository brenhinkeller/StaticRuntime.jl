# The tests of the compiler, the runtime and the language, in the order that things depend on each other.
println("\n")
@info "Core tests:"

# Strict mode, method tables, and the entry points that are not accepted; the functions that test a program
@testset verbose=true "Internals" include_timed("internals.jl")

# What goes into the binary: constants, objects, types and their tags
@testset verbose=true "Embedding" include_timed("embedding.jl")
@testset verbose=true "Types and Tags" begin
    include_timed("tags.jl")
    include_timed("subtype.jl")
    include_timed("objectid.jl")
end

# The runtime: memory and the collector, exceptions, the executable, files and the operating system
@testset verbose=true "Runtime" begin
    @testset verbose=true "Heap" include_timed("heap.jl")
    @testset verbose=true "Finalizers" include_timed("finalizers.jl")
    @testset verbose=true "Exceptions" include_timed("exceptions.jl")
    @testset verbose=true "Default Entry" include_timed("executables.jl")
    @testset verbose=true "Files and the system" include_timed("files.jl")
    @testset verbose=true "Processes" include_timed("process.jl")
    @testset verbose=true "Scripts" include_timed("scripts.jl")
    @testset verbose=true "Targets for cross-compilation" include_timed("target.jl")
end

# Dynamic dispatch, closures and C callbacks
@testset verbose=true "Inference" begin
    @testset verbose=true "Dispatch" include_timed("dispatch.jl")
    @testset verbose=true "Slots" include_timed("slots.jl")
    @testset verbose=true "Noted types" include_timed("noted.jl")
    @testset verbose=true "@assume" include_timed("assume.jl")
    @testset verbose=true "Functions" include_timed("closures.jl")
end

# The language and Base: values and globals, numbers (and random numbers), strings, collections, symbols, tasks
@testset verbose=true "Language" include_timed("language.jl")
@testset verbose=true "Numbers" include_timed("numbers.jl")
@testset verbose=true "Strings" include_timed("strings.jl")
@testset verbose=true "Symbols" include_timed("symbols.jl")
@testset verbose=true "Containers" include_timed("containers.jl")
@testset verbose=true "Tuples" include_timed("tuples.jl")
@testset verbose=true "Tasks" include_timed("tasks.jl")

# Printing
@testset verbose=true "Print, show, and display" include_timed("printing.jl")

# Libraries that the program calls
@testset verbose=true "Libraries" include_timed("libraries.jl")

# What is not supported, and what happens then
@testset verbose=true "Limitations" include_timed("limitations.jl")

# What the others left behind: the state of the process that compiles
@testset verbose=true "State" include_timed("state.jl")

# A compilation is made of the program, and of nothing that another one left
@testset verbose=true "Determinism" include_timed("determinism.jl")

# End of Core tests