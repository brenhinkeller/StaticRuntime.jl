module StaticRuntime

using Reexport: @reexport
using StaticCompiler: StaticCompiler
using GPUCompiler: GPUCompiler
using LLVM: LLVM
using InteractiveUtils: subtypes
# StaticCompiler's own entry points (and `@device_override`) are replaced by ones of ours that
# use our method table, see `entry_points.jl`
@reexport using StaticCompiler: StaticTarget
@reexport using StaticTools

# What is registered (the types that calls are made over, what is stated of types): one value, that a compilation takes
# a copy of
include("registry.jl")

# The runtime that is linked into programs (a module of its own), our method table, and our LLVM passes
include("runtime/runtime.jl")
using .Runtime: link_runtime!, UnsupportedCodeError
include("method_table.jl")   # our method table, `@device_override`, and the parameters of our compilations
include("entry_points.jl")   # `compile_executable` and the other entry points, with our method table and runtime
include("extensions.jl")     # functions that package extensions add methods to (Makie)
include("llvm/tags.jl")      # the type tags of the objects that a program allocates
include("llvm/pipeline.jl")  # the LLVM pipeline of our compilations: vectorizers, tags

# The overrides of Base that make what it does compile, by what they are for
include("overrides/strings.jl")    # building strings, CRC32c, `LazyString`, properties of characters
include("overrides/collections.jl") # vector literals, tuples, `prod`, `splice!`, `unsafe_wrap`, `Dict` of pairs
include("overrides/system.jl")     # time, `sleep`, locks, `exit` and `atexit`, libraries
include("overrides/io.jl")         # streams of libc, files, and `IOContext`
include("overrides/printing.jl")   # print, println, show, display, sprint, repr, and color
include("overrides/symbols.jl")    # Symbols that are made when the program runs
include("overrides/objectid.jl")   # objectid, so that a struct can be the key of a Dict
include("overrides/iddict.jl")     # IdDict, and with it deepcopy
include("overrides/deepcopy.jl")   # deepcopy of any struct
include("overrides/bignum.jl")     # BigInt and BigFloat
include("overrides/regex.jl")      # Regex
include("overrides/filesystem.jl") # The file system, the environment, the process
include("overrides/logging.jl")    # @warn, @info and @error, to the standard error
include("overrides/gc.jl")         # The garbage collector, from the program, and finalizers
include("overrides/tasks.jl")      # Tasks that run to completion: @async, Channel, wait, fetch

# Inference: what the compiler does with what Julia's inference leaves to the runtime. The state of a compilation, and
# the interpreter, come first: the others extend them.
include("inference/compilation.jl")     # the state of a compilation and the key of what it infers
include("inference/interpreter.jl")     # our interpreter: its method table, limits, and the small hooks
include("inference/findings.jl")        # what is found while a method is inferred, kept with its result
include("inference/redirect.jl")        # calls replaced by other calls while they are inferred
include("inference/dispatch.jl")        # calls on abstract types, split over the types that values can have
include("inference/tuples.jl")          # tuples of a few kinds, splats, fields by an index that is not known
include("inference/closures.jl")        # calls of functions that are not known: candidates, callbacks, listeners
include("inference/boxes.jl")           # the types of what the boxes of closures hold
include("inference/slots.jl")           # the types of what slots of abstract types (`Vector{Any}`, `x::Any`) hold
include("inference/types_as_values.jl") # slots that hold types (`Vector{Type}`), and keywords that are types
include("inference/objects.jl")         # the objects that the program has as constants, known one by one
include("inference/object_calls.jl")    # code of its own for each such object (`object_call`, `keyed_method`)
include("inference/assume.jl")          # types that are stated: `@assume f(::A)::R`, `@assume_field S.x::T`
include("inference/cfunctions.jl")      # `@cfunction`: C functions that call functions of the program
include("inference/optimize.jl")        # the hooks of the optimizer, and the rewrites of the optimized code
include("inference/passes.jl")          # the passes of a compilation, and what each takes from the one before
include("inference/diagnostics.jl")     # why an entry point does not infer to a concrete type

# Testing programs: differential testing against Julia, and what the code of a program needs
include("testing.jl")    # Differential testing: compiled executable vs. ordinary Julia

export compile_executable, compile_shlib, static_code_llvm, static_code_typed, static_code_native,
       static_llvm_module, @device_override
export UnsupportedCodeError, InferenceError, add_show_candidates!, add_dispatch_candidates!, @assume, @assume_field, @assume_field_embedded
export StaticIO, StaticFile, STDIN, STDOUT, STDERR
export static_result, static_status, static_status_batch, undefined_symbols, allocation_sites, @static_test
export gc_live_bytes, gc_collections, gc_heap_bytes

# What a compilation leaves behind is not an input of the next one: no compilation depends on the ones that were made
# before it. (What persists is what is not made by compiling: the overrides, the registrations of
# `add_dispatch_candidates!` and the others, and the settings.) Two things are done for it:
#
# * what a compilation finds is in the compilation (the subtypes that it listed, which modules are the program's, the
#   warnings for the user), or in the linking of its program (the addresses of the objects that it embeds), and not in a
#   table of the process;
# * what inference makes is not found by another compilation: each has the cache of its own (`Compilation.id`, which is
#   in the parameters of its jobs, and so in the token that owns the code instances), and when it ends the code
#   instances that it made are invalidated, emptied, and taken out of the lists of their methods (`purge_inferred!`).
#   `STATIC_RUNTIME_CACHE=1` makes them share the cache: compiling is faster, and what is compiled is then not made of
#   the program alone.
function purge_inferred!(c::Compilation)
    c.settings.share_cache && return nothing
    owners = IdDict{Core.MethodInstance,Vector{Any}}()
    for (mi, owner) in c.inferred
        list = get!(Vector{Any}, owners, mi)
        any(o -> o === owner, list) || push!(list, owner)
    end
    for (mi, list) in owners
        purge_owners!(mi, list)
    end
    empty!(c.inferred)
    return nothing
end

# Take the code instances of these owners out of the list that a method has (the head and the `next` of each are fields
# that Julia changes itself); the last one of the list is not taken out (a method has no way to have no list), but is
# made invalid and empty, as the others are before they are taken out: nothing can find it, and it is small.
function purge_owners!(mi::Core.MethodInstance, owners::Vector{Any})
    isdefined(mi, :cache) || return
    chain = Core.CodeInstance[]
    ci = @atomic mi.cache
    push!(chain, ci)
    while isdefined(ci, :next)
        ci = @atomic ci.next
        push!(chain, ci)
    end
    ours(ci) = any(o -> ci.owner === o, owners)
    any(ours, chain) || return
    for ci in chain
        ours(ci) || continue
        @atomic ci.max_world = UInt(0)
        @atomic ci.inferred = nothing
        @atomic ci.edges = Core.svec()
        ci.analysis_results = CC.NULL_ANALYSIS_RESULTS # (what the analysis kept with it: see `SlotFactsResult` and `InferenceFindings`)
    end
    n = length(chain)
    kept = Core.CodeInstance[ci for (i, ci) in enumerate(chain) if i == n || !ours(ci)]
    length(kept) == n && return
    # (the head is replaced only if it is the one that was read: a code instance that another thread put at the head
    # since is kept, and the list is left as it is)
    _, replaced = @atomicreplace mi.cache chain[1] => kept[1]
    replaced || return
    for i in 1:(length(kept) - 1)
        @atomic kept[i].next = kept[i + 1]
    end
    return
end

# What a process finds out about itself (the addresses of its objects, its worlds, which of its modules are Julia's) is
# the process's: when this package is loaded from its compiled image it is found out again, and not taken from the
# process that compiled it (which a workload, see `precompile.jl`, has filled it in). The registrations (`REGISTRY`) are
# the package's, and are kept. What the analysis of the slots found of a method is kept with the result of its inference
# (`SlotFactsResult`), which is in the cache, and goes with it. A compilation changes no table of the process that
# another one looks at.
function __init__()
    Runtime.forget_process_state!()
    CURRENT_COMPILATION[] = nothing
    LAST_COMPILATION[] = nothing
    return nothing
end

# Precompilation: what every compilation runs is compiled with the package (`PrecompileTools`)
include("precompile.jl")

end # module StaticRuntime
