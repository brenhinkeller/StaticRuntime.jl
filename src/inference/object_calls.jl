# Code of its own for each object that the program has as a constant.
#
# Julia propagates a constant into a call only where it is not already inferring the method with another constant
# (`is_constprop_edge_recursed`), and uses what it propagates only where the call is inlined. So a recursion over
# objects (`resolve!(node)` resolving the nodes it comes from) is known one level down at most. Here a call made for an
# object is made a call of a method specialized on the object's key (`ObjectKey{N}`), which reads the object as a
# constant (`object_for(key)`): recursion over the objects is then an ordinary recursion over methods, as finite as the
# objects. Extensions choose such methods for some calls (`keyed_method`); for any package function, `object_call`
# transplants the function's code into a method of its own for the object. Keys are numbered by compilation; with the
# shared cache (`STATIC_RUNTIME_CACHE=1`) there are none.

"""
    StaticRuntime.ObjectKey{N}

The key of an object that is a constant of the code that is compiled (see `keyed_method`): `object_for(key)` is the
object, in the code that is compiled for the key.
"""
struct ObjectKey{N} end

"""
    StaticRuntime.keyed_method(f, x)

For extensions: the function `g` that the call `f(x, args...)` is made, `g(key, args...)`, where `x` is an object that
is a constant when compiling and `key` is its `ObjectKey`; or `nothing` (the default). `g` gets the object with
`object_for(key)`. (The calls that are looked at are those of `setindex!` and `notify`.)
"""
keyed_method(@nospecialize(f), @nospecialize(x)) = nothing

"""
    StaticRuntime.object_for(key::ObjectKey)

The object of the key, as a constant, in code that is compiled.
"""
function object_for(::ObjectKey{N}) where {N}
    # (while compiling, as inference has it; there is no key otherwise)
    c = CURRENT_COMPILATION[]
    (c !== nothing && N isa Int && 1 <= N <= length(c.objects.keyed_objects)) || error("object_for: an object key is only known in compiled code")
    return c.objects.keyed_objects[N]
end

"""
    StaticRuntime.known_object_keys(f, x)

The keys of the objects of the tuple `f(x)`, made when compiling where `x` is a constant there (or a type), and
`nothing` where it is not (and when the code is not compiled). It is what `x` has when compiling, which the program may
change: for what the code checks (the listeners of an observable, which are compared with what it calls).
"""
known_object_keys(@nospecialize(f), @nospecialize(x)) = nothing # (in inference, the method is not run: see below)

keyless(@nospecialize(x)) = isbits(x) && sizeof(x) > 0

keys_on(c::Compilation) = c.settings.objects && !c.settings.share_cache

function object_key!(c::Compilation, @nospecialize(x))
    o = c.objects
    n = get!(o.key_index, x) do
        push!(o.keyed_objects, x)
        length(o.keyed_objects)
    end
    return ObjectKey{n}()
end

function keyed_call(interp::OverridesInterpreter, @nospecialize(f), arginfo::CC.ArgInfo, si::CC.StmtInfo, vtypes, sv::CC.AbsIntState)
    argtypes = arginfo.argtypes
    (length(argtypes) >= 2 && argtypes[2] isa Core.Const) || return nothing
    arginfo.fargs === nothing && return nothing # (as for `object_call_plan`: only a call that is a statement is replaced)
    c = CURRENT_COMPILATION[]
    (c !== nothing && keys_on(c)) || return nothing
    x = argtypes[2].val
    g = try Base.invokelatest(keyed_method, f, x) catch; nothing end
    g === nothing && return nothing
    # (the call `g(key, args...)` in its place: see redirect.jl)
    return redirect(interp, g, Any[object_key!(c, x)], 3, arginfo, si, vtypes, sv)
end

for F in (typeof(Base.setindex!), typeof(Base.notify))
    @eval function CC.abstract_call_known(interp::OverridesInterpreter, f::$F, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
        call = keyed_call(interp, f, arginfo, si, vtypes, sv)
        call === nothing || return call
        return julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
    end
end

# (not `:consistent`: the result belongs to the compilation, and Julia must not run the method itself on constant
# arguments (`map(key_value, keys)`); not `:inaccessiblememonly`: the object is shared memory, and a store in it is an
# effect that must not be removed with an unused call, such as a listener's)
const_call(@nospecialize(v)) = CC.Future(CC.CallMeta(CC.Const(v), Union{}, CC.Effects(CC.EFFECTS_TOTAL; consistent = CC.ALWAYS_FALSE, inaccessiblememonly = CC.ALWAYS_FALSE), CC.NoCallInfo()))

function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(object_for), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    argtypes = arginfo.argtypes
    if length(argtypes) == 2
        K = CC.widenconst(argtypes[2])
        c = CURRENT_COMPILATION[]
        if c !== nothing && K isa DataType && K <: ObjectKey && isconcretetype(K)
            n = K.parameters[1]
            n isa Int && 1 <= n <= length(c.objects.keyed_objects) && return const_call(c.objects.keyed_objects[n])
        end
    end
    return julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
end

function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(known_object_keys), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::VTypes, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    argtypes = arginfo.argtypes
    c = CURRENT_COMPILATION[]
    if c !== nothing && keys_on(c) && length(argtypes) == 3 && argtypes[3] isa Core.Const && (g = CC.singleton_type(argtypes[2])) !== nothing
        depends!(c, sv, (:closures,)) # (what `g` gives is of the compilation: the listeners that are compared with, see closures.jl and passes.jl)
        t = try Base.invokelatest(g, argtypes[3].val) catch; nothing end
        # (a value of bits that has a size has no key: it is not an object of the program that code refers to, but a
        # value, which the code would have as one of this process. Then there are none, and the code does without)
        t isa Tuple && !any(keyless, t) && return const_call(map(x -> object_key!(c, x), t))
    end
    return julia_call(interp, f, arginfo, si, vtypes, sv, max_methods)
end

# (in the code before it is optimized: the constant that a call of `object_for` or `known_object_keys` gives, which the
# statement is, or `nothing`. The calls of `setindex!` and `notify` that are made for an object are replaced as the
# others that are: see redirect.jl)
function keyed_replacement(c::Compilation, @nospecialize(called), call::Expr, @nospecialize(info), @nospecialize(t))
    (called === object_for || called === known_object_keys) || return nothing
    return t isa CC.Const ? QuoteNode(t.val) : nothing
end

## Any function, for each object
#
# A call `f(x, args...)` with a constant object `x` is made `object_call(f, key, Val(T), Val(C), args...)` (redirect.jl): a
# generated method for each key, whose code is that of `f`'s method (`ObjectCallGenerator`) with `x` read from the key.
# Arguments that are constant names (`getproperty(x, :field)`) are baked in as `C`, `(position, value)` pairs; the others
# are passed. The generated code depends only on the types (and the world), not on the compilation.
const OBJECT_CALL_MAX_ARGS = 8

struct ObjectCallGenerator <: Core.CachedGenerator end

for n in 0:OBJECT_CALL_MAX_ARGS
    args = [Symbol(:a, k) for k in 1:n]
    @eval function object_call(f, key::ObjectKey, t::Val, c::Val, $(args...))
        $(Expr(:meta, :generated, ObjectCallGenerator()))
        $(Expr(:meta, :generated_only))
    end
end

# (constants baked into the code: names only. Names are as many as the code has; numbers are not (`walk(x.next, depth +
# 1)` would be a method per level, without end over a cycle of objects), so they are passed, and Julia propagates them
# within its limits)
bakeable(@nospecialize(v)) = v isa Symbol

# (the method of `f` for an object of type `T` and the argument types, if its code can be `object_call`'s: one method,
# not generated, without varargs, `transplantable`. Looked up as the compiler does: our overrides first (`method_table`,
# which extensions add to), then Julia's)
function object_call_method(@nospecialize(F), @nospecialize(T), args, world::UInt)
    sig = Tuple{F,T,args...}
    found = try CC.findsup(sig, CC.OverlayMethodTable(world, method_table)) catch; nothing end
    found === nothing && return nothing
    match = found[1]
    match isa Core.MethodMatch || return nothing
    m = match.method
    (m.isva || isdefined(m, :generator) || m.nargs != length(args) + 2 || !isdefined(m, :source)) && return nothing
    transplantable(m, match.sparams) || return nothing
    return match
end

# (the same, once for each signature in a compilation: inference visits a call many times, in each pass)
function object_call_method(c::Compilation, @nospecialize(F), @nospecialize(T), args, world::UInt)
    key = (Tuple{F,T,args...}, world)
    cache = c.objects.call_methods
    haskey(cache, key) && return cache[key]
    return cache[key] = object_call_method(F, T, args, world)
end

# Whether the code of `m`, with static parameters `sparams`, can be the code of a method without static parameters: each
# must be a value (one that the arguments do not determine, `f(x, y::Union{S,Nothing}) where S` given `nothing`, is not),
# and the code must not use them as part of a statement rather than a value: the types of a C call (`ccall(..., (Ptr{T},),
# v)`, resolved against the compiled method's parameters), a `@cfunction`, `@isdefined T`.
function transplantable(m::Method, sparams::Core.SimpleVector)
    isempty(sparams) && return true
    any(p -> p isa TypeVar || p isa Core.SimpleVector, sparams) && return false # (a parameter that is not determined: a `TypeVar`, or as Julia 1.14 has it in a match, `svec(S, false)`)
    for st in Base.uncompressed_ir(m).code
        refers_to_parameters(st) && return false
    end
    return true
end

refers_to_parameters(@nospecialize(x)) =
    x isa Expr && (x.head === :foreigncall || x.head === :cfunction || x.head === :isdefined || x.head === :new_opaque_closure || x.head === :method || any(refers_to_parameters, x.args))

function (::ObjectCallGenerator)(world::UInt, source, @nospecialize(self), @nospecialize(F), @nospecialize(K), @nospecialize(V), @nospecialize(CV), @nospecialize(given...))
    T = V.parameters[1]
    consts = CV.parameters[1]::Tuple
    norig = length(given) + length(consts) # (the arguments of the method after the object)
    # (the type of each argument of the method after the object, and where each is: a constant, or the one of
    # `object_call` that it is given as)
    types = Vector{Any}(undef, norig)
    baked = Dict{Int,Any}(p => v for (p, v) in consts)
    runtime = Int[]
    for p in 1:norig
        if haskey(baked, p)
            types[p] = Core.Typeof(baked[p])
        else
            push!(runtime, p)
            types[p] = given[length(runtime)]
        end
    end
    match = object_call_method(F, T, types, world)
    match === nothing && return object_call_fallback(source, consts, length(given))
    orig = Base.uncompressed_ir(match.method)
    no = 2 + norig                     # (the arguments of the method: itself, the object, the others)
    nn = 5 + length(given)             # (those of `object_call`: itself, `f`, the key, the type, the constants, the others that are given)
    bakedpos = sort!(collect(keys(baked)))
    nlocal = 1 + length(bakedpos)      # (the variables that the first statements set: the object, and the constants)
    function slotmap(i::Int)
        i == 1 && return 2
        i == 2 && return nn + 1
        if i <= no
            p = i - 2
            k = findfirst(==(p), bakedpos)
            k === nothing || return nn + 1 + k
            return 5 + findfirst(==(p), runtime)
        end
        return i - no + nn + nlocal
    end
    shift = nlocal
    sparams = match.sparams
    function remap(@nospecialize(x))
        if x isa Core.SlotNumber
            return Core.SlotNumber(slotmap(x.id))
        elseif x isa Core.SSAValue
            return Core.SSAValue(x.id + shift)
        elseif x isa Core.GotoNode
            return Core.GotoNode(x.label + shift)
        elseif x isa Core.GotoIfNot
            return Core.GotoIfNot(remap(x.cond), x.dest + shift)
        elseif x isa Core.ReturnNode
            return isdefined(x, :val) ? Core.ReturnNode(remap(x.val)) : x
        elseif x isa Core.EnterNode
            dest = x.catch_dest == 0 ? 0 : x.catch_dest + shift
            return isdefined(x, :scope) ? Core.EnterNode(dest, remap(x.scope)) : Core.EnterNode(dest)
        elseif x isa Core.NewvarNode
            return Core.NewvarNode(remap(x.slot))
        elseif x isa Expr
            if x.head === :static_parameter
                v = sparams[x.args[1]]
                return v isa Symbol || v isa Expr || v isa QuoteNode ? QuoteNode(v) : v
            end
            return Expr(x.head, Any[remap(a) for a in x.args]...)
        end
        return x
    end
    code = Any[Expr(:(=), Core.SlotNumber(nn + 1), Expr(:call, GlobalRef(@__MODULE__, :object_for), Core.SlotNumber(3)))]
    for (k, p) in enumerate(bakedpos)
        v = baked[p]
        push!(code, Expr(:(=), Core.SlotNumber(nn + 1 + k), v isa Symbol ? QuoteNode(v) : v))
    end
    for st in orig.code
        push!(code, remap(st))
    end
    ci = ccall(:jl_new_code_info_uninit, Ref{Core.CodeInfo}, ())
    ci.code = code
    nstmts = length(code)
    # (the lines of the statements: those of the method's, after the ones that are put first)
    stream = CC.DebugInfoStream(nothing, orig.debuginfo, length(orig.code))
    stream.def = orig.debuginfo.def
    stream.codelocs = vcat(zeros(Int32, 3 * shift), stream.codelocs)
    ci.debuginfo = Core.DebugInfo(stream, nstmts)
    ci.ssavaluetypes = nstmts
    ci.ssaflags = vcat(zeros(UInt32, shift), orig.ssaflags)
    names, flags = orig.slotnames, orig.slotflags
    ci.slotnames = Symbol[Symbol("#self#"), :f, :key, :t, :c, (names[p + 2] for p in runtime)..., names[2], (names[p + 2] for p in bakedpos)..., names[no+1:end]...]
    ci.slotflags = UInt8[0x00, 0x00, 0x00, 0x00, 0x00, (flags[p + 2] for p in runtime)..., flags[2] | CC.SLOT_ASSIGNEDONCE, (flags[p + 2] | CC.SLOT_ASSIGNEDONCE for p in bakedpos)..., flags[no+1:end]...]
    ci.nargs = nn
    ci.isva = false
    ci.propagate_inbounds = orig.propagate_inbounds
    ci.has_fcall = orig.has_fcall
    ci.nospecializeinfer = orig.nospecializeinfer
    ci.inlining = orig.inlining
    ci.constprop = orig.constprop
    ci.purity = orig.purity
    ci.edges = Core.svec(CC.specialize_method(match))
    # (what the limits of recursion take it to be: the method of `f`, as for the code of any generated function. All of
    # these are methods of `object_call`, and calls of different functions for the same object, `viewport(scene)` and
    # `getproperty(scene, :viewport)` in it, would otherwise be one method that calls itself, which Julia limits)
    ci.method_for_inference_limit_heuristics = match.method
    ci.min_world = world
    ci.max_world = world
    return ci
end

# (a method whose code can not be taken: the call of `f` with the object, and the constants, as constants)
function object_call_fallback(source, consts::Tuple, ngiven::Int)
    given = [Symbol(:a, k) for k in 1:ngiven]
    baked = Dict{Int,Any}(p => v for (p, v) in consts)
    args, g = Any[], 0
    for p in 1:(ngiven + length(consts))
        haskey(baked, p) ? push!(args, baked[p] isa Symbol ? QuoteNode(baked[p]) : baked[p]) : push!(args, given[g += 1])
    end
    body = Expr(:call, :f, Expr(:call, GlobalRef(@__MODULE__, :object_for), :key), args...)
    loc = LineNumberNode(Int(source.line), source.file)
    lam = Expr(:lambda, [Symbol("#self#"), :f, :key, :t, :c, given...], Expr(:var"scope-block", Expr(:block, loc, Expr(:return, body))))
    return Base.generated_body_to_codeinfo(Expr(:toplevel_pure, lam), @__MODULE__, false, loc)
end

# (whether code of its own for objects of type `T` can know more than Julia's code with the object as a constant: only
# if it holds something that folds (`fold_field_read`), a field of an abstract type or one that holds an object. For a
# struct of bits and arrays, the code would be the same for each object, made again for each)
function keyable_type(c::Compilation, @nospecialize(T))
    cache = c.objects.keyable
    k = get(cache, T, nothing)
    k === nothing || return k::Bool
    found = false
    for i in 1:fieldcount(T) # (a loop: see `meets_any`)
        FT = fieldtype(T, i)
        if !isconcretetype(FT) || tracked_object_type(FT)
            found = true
            break
        end
    end
    cache[T] = found
    return found
end

# The arguments of `redirect` for a call `f(x, args...)` made for the object `x`, or `nothing`: `x` a constant object (a
# struct that is not bits), `f` a constant function with one method for the types, defined by a package (not Julia or this
# package, whose methods on objects are the accessors that reads are folded through). Gives `(f, prefix, positions)`: the
# positions of the arguments that are passed (those not baked into `C`).
function object_call_plan(c::Compilation, interp, @nospecialize(f), arginfo::CC.ArgInfo)
    (keys_on(c) && c.settings.objects) || return nothing
    # (only a call that is a statement, whose arguments are those of the statement, which is what is replaced: not one
    # that a splat makes (`f(x, t...)`, inferred from `Core._apply_iterate`), nor one that a replacement makes)
    arginfo.fargs === nothing && return nothing
    argtypes = arginfo.argtypes
    n = length(argtypes) - 2
    0 <= n || return nothing
    x = argtypes[2]
    (x isa Core.Const && tracked_object_type(typeof(x.val))) || return nothing
    # (not a type, nor another object of Julia's own (a binding, a `TypeVar`): what is called with those is chosen by
    # the value, `::Type{T}`, and they are not what a package keeps its state in)
    (x.val isa Type || parentmodule(typeof(x.val)) === Core) && return nothing
    keyable_type(c, typeof(x.val)) || return nothing
    f isa Core.Builtin && return nothing
    F = typeof(f)
    Base.issingletontype(F) || return nothing
    any(a -> a isa Core.TypeofVararg, argtypes) && return nothing
    consts, positions, types = Tuple{Int,Any}[], Int[], Any[]
    for (p, t) in enumerate(argtypes[3:end])
        if t isa Core.Const && bakeable(t.val)
            push!(consts, (p, t.val)); push!(types, Core.Typeof(t.val))
        else
            push!(positions, p + 2); push!(types, CC.widenconst(t))
        end
    end
    length(positions) <= OBJECT_CALL_MAX_ARGS || return nothing
    # (the arguments that are given are of types that are concrete: a method for an argument of an abstract type is
    # called by the runtime's convention, `jl_invoke`)
    all(i -> isconcretetype(types[i - 2]), positions) || return nothing
    match = object_call_method(c, F, typeof(x.val), types, CC.get_inference_world(interp))
    match === nothing && return nothing
    mod = Base.moduleroot(match.method.module)
    (mod === Base || mod === Core || mod === CC || mod === @__MODULE__) && return nothing
    return (object_call, Any[f, object_key!(c, x.val), Val(typeof(x.val)), Val(Tuple(consts))], positions)
end

# (whether the signature of a call has a key in it: one of a method that is compiled for an object, see above, whose
# recursion is not limited)
is_key_type(@nospecialize(p)) = p isa DataType && p <: ObjectKey

has_object_key(@nospecialize(sig)) = sig isa DataType && any(p -> is_key_type(p) || (p isa DataType && p <: Tuple && !(p <: Tuple{}) && any(is_key_type, p.parameters)), sig.parameters)

# The keys of a signature, in order (of its arguments, and of the elements of tuple arguments). Recursion from a frame for
# other objects is not limited: what it reaches is as finite as the objects, as long as recursion back to the same objects
# with other arguments (a growing number or tuple, over a cycle) is limited as Julia limits any recursion. (The other
# arguments may change from one object to the next: an observable's update sets another of another value type.)
function object_keys(@nospecialize(sig), out::Vector{Any} = Any[])
    sig isa DataType || return out
    # (for `object_call`, the names that are constants too (`Val{C}`): there are as many as the code has, and
    # `setproperty!(graph, :a, x)` that sets `graph.b` is not a recursion that grows)
    length(sig.parameters) >= 5 && sig.parameters[1] === typeof(object_call) && push!(out, sig.parameters[5])
    for p in sig.parameters
        if is_key_type(p)
            push!(out, p)
        elseif p isa DataType && p <: Tuple && !(p <: Tuple{})
            object_keys(p, out)
        end
    end
    return out
end
