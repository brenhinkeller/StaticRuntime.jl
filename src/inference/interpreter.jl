# The interpreter of our compilations.
#
# Inference is extended with methods of the compiler's functions (`abstract_call_known`, `abstract_call_gf_by_type`,
# `optimize`, ...) for the interpreter that inference is given. GPUCompiler's `GPUInterpreter` is also what
# StaticCompiler's own compilations use, so methods for it would change those too. Instead our compilations get a type
# of their own: a `GPUInterpreter` is parameterized by the view of the method tables that it looks methods up in, and
# GPUCompiler lets a back end choose that view (`method_table_view`). Ours, `OverridesTableView`, wraps GPUCompiler's
# and behaves the same; `OverridesInterpreter` is the interpreter with it, and every hook in `src/inference` is a method
# for that type.

const CC = Base.Compiler

# The most concrete subtypes of an abstract type that are listed and dispatched over.
const DISPATCH_LIMIT = Ref(16)

# The most cases that a call is split in, over listed subtypes or registered types. (Julia limits splitting by the
# number of cases: `x + y` of two arguments of 23 types is not split with a limit of 32, and is with 64.) `0` turns off
# the use of the registered types.
const SPLIT_LIMIT = Ref(64)

# Julia's inference splits a union of at most 4 types by default; ours, as many as we dispatch over.
function GPUCompiler.inference_params(job::GPUCompiler.CompilerJob{<:StaticCompiler.StaticCompilerTarget, OverridesParams})
    base = @invoke GPUCompiler.inference_params(job::GPUCompiler.CompilerJob)
    job.config.target.method_table === method_table || return base
    return CC.InferenceParams(base; max_union_splitting = max(base.max_union_splitting, job.config.params.split_limit))
end

"""
    OverridesTableView

The view of the method tables of our compilations: GPUCompiler's (the compilation's table, then Base's), in a type of
our own, so that the interpreter that has it is told apart from others by its type.
"""
struct OverridesTableView{T<:CC.MethodTableView} <: CC.MethodTableView
    inner::T
end
CC.isoverlayed(table::OverridesTableView) = CC.isoverlayed(table.inner)
CC.findall(@nospecialize(sig::Type), table::OverridesTableView; kwargs...) = CC.findall(sig, table.inner; kwargs...)
CC.findsup(@nospecialize(sig::Type), table::OverridesTableView) = CC.findsup(sig, table.inner)

GPUCompiler.method_table_view(job::GPUCompiler.CompilerJob{<:StaticCompiler.StaticCompilerTarget, OverridesParams}) =
    OverridesTableView(@invoke GPUCompiler.method_table_view(job::GPUCompiler.CompilerJob))

# (the interpreter keeps the view in a cache, `CachedMethodTable`)
const OverridesInterpreter = GPUCompiler.GPUInterpreter{<:Union{OverridesTableView, CC.CachedMethodTable{<:OverridesTableView}}}

# A tuple with a `Union` element (`Tuple{Union{Vector{Float64},Vector{ComplexF64}},Int}`) is not a concrete type: Julia
# builds it with `jl_f_tuple`, which needs the runtime. Where the function that returns it is inlined, the tuple is
# never built. Julia gives such functions an inlining bonus (`inline_tupleret_bonus`, 400); ours is ten times that
# (enough for `eigs` of Graphs.jl).
CC.OptimizationParams(interp::OverridesInterpreter) = CC.OptimizationParams(interp.opt_params; inline_tupleret_bonus = 4_000)

# The variables of a frame, as the hooks are given them.
const VTypes = Union{Nothing,Vector{CC.VarState}}

# Julia's own inference of a call of a known function: what a hook of `abstract_call_known` gives when it changes
# nothing.
julia_call(interp::CC.AbstractInterpreter, @nospecialize(f), arginfo::CC.ArgInfo, si::CC.StmtInfo, vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int) =
    @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo, vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int)

## `@nospecializeinfer`
#
# A `@nospecializeinfer` method is inferred for its declared argument types, not those of the call (Makie's
# `node_pairs(@nospecialize(nt::NamedTuple))` sees a `NamedTuple` with no known fields, so everything it does with them
# dispatches). A static program needs the precise types, so the flag is cleared for as long as a compilation runs
# (`restore_nospecializeinfer!` puts it back; `STATIC_RUNTIME_NOSPECIALIZEINFER=0` leaves it).
function CC.abstract_call_method(interp::OverridesInterpreter, method::Method, @nospecialize(sig), sparams::Core.SimpleVector, hardlimit::Bool, si::CC.StmtInfo, sv::CC.AbsIntState)
    c = compilation()
    if c.settings.precise_nospecializeinfer && method.nospecializeinfer
        method.nospecializeinfer = false
        push!(c.nospecializeinfer, method)
    end
    return @invoke CC.abstract_call_method(interp::CC.AbstractInterpreter, method::Method, sig::Any, sparams::Core.SimpleVector, hardlimit::Bool, si::CC.StmtInfo, sv::CC.AbsIntState)
end

function restore_nospecializeinfer!(c::Compilation)
    for m in c.nospecializeinfer
        m.nospecializeinfer = true
    end
    empty!(c.nospecializeinfer)
    return
end

## The standard streams
#
# Base's `stdout`, `stderr` and `stdin` are globals of the abstract type `IO` (libuv streams), and the default of what
# packages print to, so calls on them dispatch over every `IO`. A program has libc's streams instead (`STDOUT`,
# `STDERR`, `STDIN`, io.jl): a read of Base's globals is one of them, both for inference and in the code.
const STANDARD_STREAMS = (; stdin = STDIN, stdout = STDOUT, stderr = STDERR)

# (the stream that a global is, or `nothing`)
function standard_stream(@nospecialize(g))
    g isa GlobalRef && g.name in keys(STANDARD_STREAMS) || return nothing
    return Base.binding_module(g.mod, g.name) in (Base, Core) ? getfield(STANDARD_STREAMS, g.name) : nothing
end

function CC.abstract_eval_globalref(interp::OverridesInterpreter, g::GlobalRef, saw_latestworld::Bool, sv::CC.AbsIntState)
    stream = standard_stream(g)
    stream === nothing || return CC.RTEffects(CC.Const(stream), Union{}, CC.EFFECTS_TOTAL)
    rt = @invoke CC.abstract_eval_globalref(interp::CC.AbstractInterpreter, g::GlobalRef, saw_latestworld::Bool, sv::CC.AbsIntState)
    # (a global that is not `const` and has no type is read as `Any`: calls on it are made over the types that it holds,
    # which the program that compiles has the first of, and the code assigns the rest)
    if CC.widenconst(rt.rt) === Any && CURRENT_COMPILATION[] !== nothing && isdefined(g.mod, g.name) && !isconst(g.mod, g.name)
        note_universe!(CURRENT_COMPILATION[], typeof(getglobal(g.mod, g.name)); force = true)
    end
    return rt
end

# (in the code before it is optimized, so that what the code loads is what inference said)
function replace_standard_streams!(code::Vector{Any})
    for pc in eachindex(code)
        st = code[pc]
        stream = standard_stream(st)
        if stream !== nothing
            code[pc] = stream
        elseif st isa Expr
            replace_standard_streams!(st.args)
        end
    end
    return
end

## `invokelatest` and `fma`

# `invokelatest(f, args...)` calls `f` in the newest world, which only the runtime knows. A compiled program has no
# newer methods, so it is the call `f(args...)`, both for inference and in the code (see `optimize`). Packages use it in
# logging macros (`@warn`) and to cut recursions that inference gives up on.
function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(Core.invokelatest), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    if length(arginfo.argtypes) >= 2
        inner = CC.ArgInfo(arginfo.fargs === nothing ? nothing : arginfo.fargs[2:end], arginfo.argtypes[2:end])
        return CC.abstract_call(interp, inner, si, vtypes, sv)
    end
    return julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
end

# `Core.Intrinsics.have_fma(T)` (asked by `fma`, `muladd`, `log`, `^`, ...) is answered when code is generated, from the
# features of the function it is in, which a program's functions lack: the answer would be no, and `fma` would be done
# in software, many times slower. The program is made for the machine that compiles it, so Julia's answer there is used.
function CC.abstract_call_known(interp::OverridesInterpreter, f::Core.IntrinsicFunction, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    if f === Core.Intrinsics.have_fma && length(arginfo.argtypes) == 2
        t = arginfo.argtypes[2]
        T = t isa Core.Const ? t.val : (t isa DataType && t <: Type && t.parameters[1] isa DataType ? t.parameters[1] : nothing)
        if T isa DataType && T in (Float16, Float32, Float64)
            return CC.Future(CC.CallMeta(Core.Const(Core.Intrinsics.have_fma(T)), Union{}, CC.EFFECTS_TOTAL, CC.NoCallInfo()))
        end
    end
    return julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
end

# `Core.stderr`, `Core.stdout` and `Core.stdin` are read as `getproperty(Core, :stderr)`,
# which inference folds to the object that Julia has (and evaluates, without looking at what is in it): 
# the same streams as for Base's globals.
function standard_stream_of_call(arginfo::CC.ArgInfo)
    at = arginfo.argtypes
    length(at) == 3 && at[2] isa Core.Const && at[3] isa Core.Const && at[2].val isa Module && at[3].val isa Symbol || return nothing
    return standard_stream(GlobalRef(at[2].val, at[3].val))
end
for getter in (:getglobal, :getproperty) # (`getfield` is in boxes.jl)
    @eval function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof($getter), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
        stream = standard_stream_of_call(arginfo)
        stream === nothing || return CC.Future(CC.CallMeta(Core.Const(stream), Union{}, CC.EFFECTS_TOTAL, CC.NoCallInfo()))
        return julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
    end
end

## Reading code

# Whether a binding partition (how optimized code refers to a global) is a constant's: then it holds the value.
is_const_partition(x::Core.BindingPartition) = (x.kind & 0x0f) in (Base.PARTITION_KIND_CONST, Base.PARTITION_KIND_CONST_IMPORT, Base.PARTITION_KIND_IMPLICIT_CONST, Base.PARTITION_KIND_BACKDATED_CONST)

# The function that the callee `x` of a statement refers to (directly, through a `GlobalRef`, or through an earlier
# statement: `getproperty(Base, :invokelatest)`), or `nothing`.
function called_function(code, x)
    x isa Core.SSAValue && (x = code[x.id])
    if x isa Expr && x.head === :call && length(x.args) == 3
        f = called_function(code, x.args[1])
        if f === getproperty || f === getglobal
            mod = called_function(code, x.args[2])
            name = x.args[3] isa QuoteNode ? x.args[3].value : x.args[3]
            return mod isa Module && name isa Symbol && isdefined(mod, name) ? getglobal(mod, name) : nothing
        end
        return nothing
    end
    x isa GlobalRef && return isdefined(x.mod, x.name) ? getglobal(x.mod, x.name) : nothing
    x isa QuoteNode && return x.value
    x isa Core.BindingPartition && return is_const_partition(x) ? x.restriction : nothing
    return x isa Expr ? nothing : x
end
