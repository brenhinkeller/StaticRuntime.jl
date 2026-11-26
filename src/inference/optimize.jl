# The hooks of the optimizer, and the rewrites that this package makes in the optimized code: replaced calls are written
# in (`RedirectInfo`), facts of the code are recorded for the slot and object analyses (`ssa_inlining_pass!`), reads of
# slots are checked (`check_slot_reads!`), and constructs that a static binary can not run are rewritten.

# Before optimizing: replaced calls are written in, `invokelatest` becomes the call it was inferred as, and what the
# code shows of functions and boxes is recorded.
function CC.optimize(interp::OverridesInterpreter, opt::CC.OptimizationState, caller::CC.InferenceResult)
    code = opt.src.code
    replace_standard_streams!(code)
    c = compilation()
    findings = caller.overridden_by_const === nothing ? findings!(caller) : nothing # (what is found of the code is kept with its result, for the compilations that take it from the cache: see `InferenceFindings`)
    c.closures.sink = findings
    try
        note_functions_of!(c.closures, code, opt.src.ssavaluetypes, caller.linfo) # (the functions that the code has: see closures.jl)
    finally
        c.closures.sink = nothing
    end
    if caller.linfo isa Core.MethodInstance
        findings === nothing || any(st -> box_creation(code, st) !== nothing, code) && push!(findings.boxes, (copy(opt.src), caller.linfo))
        learn_boxes!(c.boxes, opt.src, caller.linfo) # (the types of the boxes of the code: see boxes.jl)
    end
    for pc in eachindex(code)
        st = code[pc]
        # (a call that is assigned to a variable is the second of the arguments of `=`)
        assigned = st isa Expr && st.head === :(=) && length(st.args) == 2 && st.args[2] isa Expr
        call = assigned ? st.args[2] : st
        call isa Expr && call.head === :call && length(call.args) >= 2 || continue
        called = called_function(code, call.args[1])
        # (`NamedTuple{names}(args)` that was given the type of its argument, see `abstract_call_known` for `NamedTuple`
        # in types_as_values.jl: the call is of the type that it gives, as the code that is made of it makes a value of
        # the type that it is called)
        let t = opt.src.ssavaluetypes[pc], called = (a = call.args[1]; a isa Core.SSAValue && (ft = opt.src.ssavaluetypes[a.id]) isa CC.Const ? ft.val : called)
            if called isa UnionAll && called.body isa DataType && called.body.name === Base.typename(NamedTuple) && length(call.args) == 2 &&
               t isa DataType && t.name === Base.typename(NamedTuple) && t !== called && t <: called
                call.args[1] = t
                continue
            end
        end
        # (the keywords of a call that has a type as a value: the constant that the call is given is one of the type
        # that has the type as the type of the field, as the method was inferred for, see `typed_keywords`. Only the
        # argument of the call: the value is what it is everywhere else, and `typeof` of it is what Julia says)
        if called === Core.kwcall && length(call.args) >= 2
            kw = call.args[2]
            t = kw isa Core.SSAValue ? opt.src.ssavaluetypes[kw.id] : kw isa NamedTuple ? CC.Const(kw) : nothing
            t isa CC.Const && has_type_values(t.val) && (call.args[2] = typed_constant(t.val))
        end
        info = opt.stmt_info[pc]
        if info isa RedirectInfo
            # (a call that is replaced, see "Calls that are replaced": the call of the replacement, with what inference
            # has of it)
            replacement = Expr(:call, info.f, info.prefix..., call.args[info.positions]...)
            opt.stmt_info[pc] = info.info
            assigned ? (st.args[2] = replacement) : (code[pc] = replacement)
            continue
        end
        replacement = if called === host_text && opt.src.ssavaluetypes[pc] isa CC.Const
            # (the text that was made when compiling, see `host_text` in overrides/printing.jl: the statement is the text, which Julia
            # does not put in the place of a call that it is the value of, as it is not a value of bits)
            opt.src.ssavaluetypes[pc].val
        elseif called === Core.invokelatest
            Expr(:call, call.args[2:end]...)
        elseif (called === Core.memoryrefget || called === Core.getfield) && (slot_call = type_slot_call(opt.stmt_info[pc])) !== nothing
            slot_call[1] === type_slot_get ? Expr(:call, type_slot_get, call.args[2], slot_call[2]) : Expr(:call, type_slot_field, call.args[2], Val(call.args[3] isa QuoteNode ? call.args[3].value : call.args[3]), slot_call[2])
        elseif (keyed = keyed_replacement(c, called, call, opt.stmt_info[pc], opt.src.ssavaluetypes[pc])) !== nothing
            # (code for each object, and the constants that it has: see object_calls.jl)
            keyed
        elseif called === call_callback && length(call.args) >= 3
            # (`call_callback(T, f, args...)` is `f(args...)`, or no call at all where no function was registered for
            # `T`: see closures.jl)
            opt.src.ssavaluetypes[pc] === Union{} ? Expr(:call, Core.throw, "a callback that was not registered") : Expr(:call, call.args[3:end]...)
        else
            continue
        end
        assigned ? (st.args[2] = replacement) : (code[pc] = replacement)
    end
    # (what the analysis of the slots finds of the code of this method is kept with its result: see `SlotFactsResult`)
    previous = c.slots.current_result
    c.slots.current_result = caller
    try
        if c.trace.on
            c.closures.optimized += 1
            push!(c.closures.optimized_unique, caller.linfo)
            started = time_ns()
            result = @invoke CC.optimize(interp::CC.AbstractInterpreter, opt::CC.OptimizationState, caller::CC.InferenceResult)
            note_slow_optimization!(c.closures, caller.linfo, (time_ns() - started) / 1e9, length(code))
            return result
        end
        return @invoke CC.optimize(interp::CC.AbstractInterpreter, opt::CC.OptimizationState, caller::CC.InferenceResult)
    finally
        c.slots.current_result = previous
    end
end

function CC.ssa_inlining_pass!(ir::CC.IRCode, state::CC.InliningState{<:OverridesInterpreter}, propagate_inbounds::Bool)
    mi = ir.debuginfo.def
    c = compilation()
    mi isa Core.MethodInstance && c.slots.mode !== :off && record_slot_facts!(c, ir, mi)
    # (without the slots, the constants are still looked at for their listeners, which are not known otherwise: see
    # "Listeners" in closures.jl)
    c.slots.mode === :off && note_slots_in_constants!(c, (ir.stmts[pc][:stmt] for pc in 1:length(ir.stmts)))
    inlined = @invoke CC.ssa_inlining_pass!(ir::CC.IRCode, state::CC.InliningState, propagate_inbounds::Bool)
    mi isa Core.MethodInstance && c.slots.mode !== :off && c.settings.objects && record_object_facts!(c, inlined, mi)
    return inlined
end

function CC.finishopt!(interp::OverridesInterpreter, opt::CC.OptimizationState, ir::CC.IRCode)
    c = compilation()
    ir = assert_assumed_returns!(c, ir, opt.linfo)
    # (not in `type_slot_get` and `type_slot_field`: what they read is what they check)
    (c.settings.check_types || !isempty(c.registered.fields) || !isempty(c.registered.embedded)) && !in_type_slot_read(opt) && (ir = check_slot_reads!(c, ir))
    ir = assert_field_receivers!(ir)
    ir = expand_type_value_tests!(ir)
    ir = concretize_type_tuples!(ir)
    ir = expand_tuple_reads!(ir)
    ir = expand_setproperty!(ir)
    t = c.trace
    t.methoderrors && trace_method_errors(ir, opt.linfo)
    t.methoderrors && trace_noreturn(ir, opt.linfo) # (not with `STATIC_RUNTIME_TRACE=1`: in a large program there are thousands, and writing their types took a quarter of the time)
    ir = concretize_namedtuples!(ir)
    ir = remove_unused_type_construction!(ir)
    # (`STATIC_RUNTIME_TRACE=ir:<text>`: the code of the methods whose name has the text in it, as it is now)
    isempty(t.ir) || (name = string(opt.linfo); occursin(t.ir, name) && trace("the code of ", name, ", optimized:\n", ir))
    return @invoke CC.finishopt!(interp::CC.AbstractInterpreter, opt::CC.OptimizationState, ir::CC.IRCode)
end

# Reads of slots with types (slots.jl) are `typeassert`ed to those types, so that stores the analysis missed are found
# when the program runs (without the types they would be `Any`, dispatched over the registered types). Only for reads
# narrower than the slot's declared type.
function check_slot_reads!(c::Compilation, ir::CC.IRCode)
    changed = false
    reads = Dict{Int,SlotKey}() # (the statements that read a slot that was given types, and are checked)
    for pc in 1:length(ir.stmts)
        st = ir.stmts[pc][:stmt]
        st isa Expr && st.head === :call && length(st.args) >= 3 || continue
        f = CC.singleton_type(CC.argextype(st.args[1], ir))
        key = nothing
        if f === Core.getfield
            name = CC.argextype(st.args[3], ir)
            name isa Core.Const && (name.val isa Symbol || name.val isa Integer) || continue
            key = field_slot_key(CC.argextype(st.args[2], ir), name.val)
        elseif f === Core.memoryrefget
            key = elem_slot_key(CC.argextype(st.args[2], ir))
        else
            continue
        end
        key === nothing && continue
        # (a read of a slot that was given types, or of a field of an object that is known: see objects.jl)
        (slot_read_type(c, key) !== nothing || (f === Core.getfield && known_object(c, CC.argextype(st.args[2], ir)) !== nothing)) || continue
        (c.settings.check_types || haskey(c.registered.fields, key) || key in c.registered.embedded) || continue # (what is assumed is always checked)
        reads[pc] = key
        T = CC.widenconst(ir.stmts[pc][:type])
        (T !== Union{} && closed_type(T)) || continue
        wide = key[1] === :elem ? key[2] : fieldtype(key[2], key[3])
        T === wide && continue
        read = CC.insert_node!(ir, pc, CC.NewInstruction(st, wide), false)
        ir.stmts[pc][:stmt] = Expr(:call, Core.typeassert, read, T)
        changed = true
    end
    # (a read that inference narrowed with a `PiNode` of its value, which is not a check: it is the type that was
    # claimed, and one that the value may not have)
    for pc in 1:length(ir.stmts)
        st = ir.stmts[pc][:stmt]
        st isa Core.PiNode && st.val isa Core.SSAValue && haskey(reads, st.val.id) && st.typ isa Type || continue
        ir.stmts[pc][:stmt] = Expr(:call, Core.typeassert, st.val, st.typ)
        changed = true
    end
    return changed ? CC.compact!(ir) : ir
end

## Fields of `Union{T,Nothing}`
#
# `node.next.value` with `node.next::Union{Node,Nothing}`: Julia splits calls on the union when it inlines them, but the
# inlined code still reads `getfield(x, :value)` of the union, a runtime call (`jl_f_getfield`). Only the non-`Nothing`
# member has the field, so the value is asserted to be of it first: `nothing` stops the program, as Julia's `FieldError`
# does.
const FIELD_BUILTINS = (Core.getfield, Core.setfield!)

# (for `STATIC_RUNTIME_TRACE`: the calls that have no method for the types that reach them, which abort the program if
# they are reached: the function, the types of the arguments, and the method that has the call)
function trace_method_errors(ir::CC.IRCode, linfo)
    for pc in 1:length(ir.stmts)
        st = ir.stmts[pc][:stmt]
        st isa Expr && st.head === :call || continue
        f = st.args[1]
        (f === Core.throw_methoderror || (f isa GlobalRef && f.name === :throw_methoderror)) || continue
        trace("no method for ", join((CC.widenconst(CC.argextype(a, ir)) for a in st.args[2:end]), ", "), " in ", linfo)
    end
    return
end

# (for the trace) A type with `Union{}` as a parameter (`Pairs{Symbol,Union{},...}`, `Type{Union{}}`) has no values, so a
# call with an argument of it gives none and what follows is unreachable. Where inference is wrong about a type (it was
# for `eltype` of some tuple types: see `_compute_eltype` in overrides/collections.jl), the program silently has a trap there.
function has_bottom_parameter(@nospecialize(T), depth::Int = 0)
    depth > 6 && return false
    T = CC.widenconst(T)
    if T isa Union
        return any(U -> has_bottom_parameter(U, depth + 1), Base.uniontypes(T))
    elseif T isa DataType || T isa Core.TypeEq # (`Type{X}` is a `TypeEq`, not a `DataType`, in Julia 1.14)
        for P in (T isa Core.TypeEq ? (Base.type_parameter(T),) : T.parameters)
            P === Union{} && return true
            P isa Type && has_bottom_parameter(P, depth + 1) && return true
        end
    end
    return false
end

# (for `STATIC_RUNTIME_TRACE`: the calls that give no value, and have an argument that has a type that no value has, or
# a `NamedTuple` that is not a concrete type, which is what a call is inferred for when what made its argument was given
# the wrong type. A call that always throws has no such argument: those are not shown)
function trace_noreturn(ir::CC.IRCode, linfo)
    for pc in 1:length(ir.stmts)
        ir.stmts[pc][:type] === Union{} || continue
        st = ir.stmts[pc][:stmt]
        st isa Expr && (st.head === :call || st.head === :invoke) || continue
        args = st.head === :invoke ? st.args[2:end] : st.args
        length(args) >= 1 || continue
        types = Any[CC.widenconst(CC.argextype(a, ir)) for a in args]
        f = CC.singleton_type(types[1])
        (f === Core.throw || f === Core.Intrinsics.llvmcall) && continue
        suspicious = [T for T in types[2:end] if has_bottom_parameter(T) || (T isa DataType && T.name === Base.typename(NamedTuple) && !isconcretetype(T))]
        isempty(suspicious) && continue
        trace("the call ", f === nothing ? types[1] : f, "(", join(types[2:end], ", "), ") gives no value, and an argument of it has a type that no value has or is not concrete: ", join(suspicious, ", "), " in ", linfo)
    end
    return
end

## Rewrites of the optimized code

# Types that are built and not used: `x isa CallbackSet{<:AbstractVector,<:AbstractVector}`, answered by inference,
# leaves the statements that build the type (`Core._typevar`, `Core.apply_type`), runtime calls that Julia keeps because a
# `TypeVar` is mutable. Unused statements of these kinds are removed, with those only they used.
const TYPE_BUILDERS = (Core._typevar, Core.apply_type, Core.UnionAll)

function remove_unused_type_construction!(ir::CC.IRCode)
    n = length(ir.stmts)
    candidates = Int[]
    for pc in 1:n
        st = ir.stmts[pc][:stmt]
        st isa Expr && st.head === :call && !isempty(st.args) || continue
        CC.singleton_type(CC.argextype(st.args[1], ir)) in TYPE_BUILDERS && push!(candidates, pc)
    end
    isempty(candidates) && return ir
    uses = zeros(Int, n)
    for pc in 1:n
        for ur in CC.userefs(ir.stmts[pc][:stmt])
            v = ur[]
            v isa Core.SSAValue && v.id <= n && (uses[v.id] += 1)
        end
    end
    changed = false
    for pc in reverse(candidates)
        uses[pc] == 0 || continue
        st = ir.stmts[pc][:stmt]
        for ur in CC.userefs(st)
            v = ur[]
            v isa Core.SSAValue && v.id <= n && (uses[v.id] -= 1)
        end
        ir.stmts[pc][:stmt] = nothing
        ir.stmts[pc][:type] = Nothing
        changed = true
    end
    return changed ? CC.compact!(ir) : ir
end

function assert_field_receivers!(ir::CC.IRCode)
    changed = false
    for pc in 1:length(ir.stmts)
        st = ir.stmts[pc][:stmt]
        st isa Expr && st.head === :call && length(st.args) >= 3 || continue
        CC.singleton_type(CC.argextype(st.args[1], ir)) in FIELD_BUILTINS || continue
        receiver = CC.widenconst(CC.argextype(st.args[2], ir))
        receiver isa Union || continue
        members = Base.uniontypes(receiver)
        parts = filter(T -> !(T === Nothing || T === Missing), members)
        if !(length(parts) == 1 && isconcretetype(only(parts)) && length(members) > 1)
            # (a union of types of which one has the field that is read or written, `info.bound` where `info` is a `VariableIndex` or a
            # `_VariableInfo`: Julia narrows the receiver after an `isa` or a call that only one of them has a method for, and the narrowed
            # type is that of the field. Where the code does not have the narrowing, the access of a field of a union is a call at run time)
            name = CC.argextype(st.args[3], ir)
            name isa Core.Const && (name.val isa Symbol || name.val isa Int) || continue
            having = [T for T in members if T isa DataType && isconcretetype(T) && isstructtype(T) && !(T <: Type) &&
                                          (name.val isa Symbol ? hasfield(T, name.val) : 1 <= name.val <= fieldcount(T))]
            length(having) == 1 && length(members) > 1 || continue
            parts = having
        end
        T = only(parts)
        checked = CC.insert_node!(ir, pc, CC.NewInstruction(Expr(:call, Core.typeassert, st.args[2], T), T), false)
        st.args[2] = checked
        changed = true
    end
    return changed ? CC.compact!(ir) : ir
end

# `getfield(t, i)` of a tuple by an index that is not a constant (`t[i]` in a loop): Julia infers the union of the
# element types, narrower than what `index_field` gives for constant elements (inference makes more than three constant
# types `DataType`), and the slot analysis reads stored types from the call (`Type[A, B, C, D]`). So it is left as Julia's
# call through optimization and made a call of `index_field` afterwards. (Fields of other structs are replaced during
# inference: see `dynamic_field_plan`.)
function expand_tuple_reads!(ir::CC.IRCode)
    for pc in 1:length(ir.stmts)
        st = ir.stmts[pc][:stmt]
        st isa Expr && st.head === :call && 3 <= length(st.args) <= 4 || continue
        CC.singleton_type(CC.argextype(st.args[1], ir)) === Core.getfield || continue
        i = CC.argextype(st.args[3], ir)
        (!(i isa Core.Const) && CC.widenconst(i) === Int) || continue
        T = CC.widenconst(CC.argextype(st.args[2], ir))
        (T isa DataType && T <: Tuple && isconcretetype(T) && Base.datatype_fieldcount(T) isa Int && 0 < Base.datatype_fieldcount(T) <= 64) || continue
        mi = CC.specialize_method(only(methods(index_field)), Tuple{typeof(index_field),T,Int}, Core.svec())
        ir.stmts[pc][:stmt] = Expr(:invoke, mi, index_field, st.args[2], st.args[3])
        # (the elements of a tuple of types that is a constant: each is a type that is known, see
        # `types_of_constant_tuple`, where the callee gives the `DataType` that they are all of)
        types = types_of_constant_tuple(Any[nothing, CC.argextype(st.args[2], ir), i])
        types === nothing || (ir.stmts[pc][:type] = types)
    end
    return ir
end

# `x.name = v` that Julia did not inline (`setproperty!(x, :name, v)`, where converting `v` has no method or is large) is
# a call of `setproperty!`'s one method, which has the name as a value and sets the field with runtime calls. The name is
# a constant at the call: where `v` is of the field's type the call becomes the `setfield!`, and where `convert` has no
# method it becomes the error that it gives.
const SETPROPERTY_SIG = Tuple{typeof(Base.setproperty!),Any,Symbol,Any}

function expand_setproperty!(ir::CC.IRCode)
    for pc in 1:length(ir.stmts)
        st = ir.stmts[pc][:stmt]
        st isa Expr && st.head === :invoke && length(st.args) == 5 || continue
        mi = st.args[1]
        mi isa Core.CodeInstance && (mi = mi.def)
        mi isa Core.MethodInstance && mi.def isa Method && mi.def.sig === SETPROPERTY_SIG || continue
        name = CC.argextype(st.args[4], ir)
        name isa Core.Const && name.val isa Symbol || continue
        T = CC.widenconst(CC.argextype(st.args[3], ir))
        (T isa DataType && isconcretetype(T) && isstructtype(T) && !(T <: Type) && hasfield(T, name.val)) || continue
        V = CC.widenconst(CC.argextype(st.args[5], ir))
        isconcretetype(V) || continue
        FT = fieldtype(T, name.val)
        if V <: FT
            ir.stmts[pc][:stmt] = Expr(:call, Core.setfield!, st.args[3], QuoteNode(name.val), st.args[5])
        elseif FT isa DataType && isempty(methods(convert, Tuple{Type{FT},V}))
            ir.stmts[pc][:stmt] = Expr(:call, Core.throw_methoderror, Base.convert, FT, st.args[5])
        end
    end
    return ir
end

## `NamedTuple`s made of values of the type `Any`
#
# `(; label, value)` with `value::Any` builds a tuple and gets the `NamedTuple`'s type from `typeof(tuple)`, the type of
# the values when the program runs, which an executable can not make (`jl_f_tuple`, `jl_f_apply_type`). The type that
# inference gives the tuple (`Tuple{Symbol,Any}`) is the one the `NamedTuple` has where it is stored with that type (in a
# `Vector` of them), so the tuple's type is taken to be that.
function concretize_namedtuples!(ir::CC.IRCode)
    changed = false
    for pc in 1:length(ir.stmts)
        st = ir.stmts[pc][:stmt]
        st isa Expr && st.head === :call && length(st.args) == 4 || continue
        CC.singleton_type(CC.argextype(st.args[1], ir)) === Core.apply_type || continue
        CC.singleton_type(CC.argextype(st.args[2], ir)) === NamedTuple || continue
        names = CC.argextype(st.args[3], ir)
        names isa Core.Const && names.val isa Tuple{Vararg{Symbol}} || continue
        tt = st.args[4]
        tt isa Core.SSAValue || continue
        tst = ir.stmts[tt.id][:stmt]
        tst isa Expr && tst.head === :call && length(tst.args) == 2 || continue
        CC.singleton_type(CC.argextype(tst.args[1], ir)) === Core.typeof || continue
        T = CC.widenconst(CC.argextype(tst.args[2], ir))
        T isa DataType && T <: Tuple && !isconcretetype(T) && !(T isa UnionAll) && length(T.parameters) == length(names.val) || continue
        any(p -> p isa Core.TypeVar || p isa Core.TypeofVararg, T.parameters) && continue
        N = NamedTuple{names.val,T}
        isconcretetype(N) || continue
        ir.stmts[tt.id][:stmt] = T
        ir.stmts[tt.id][:type] = Core.Const(T)
        ir.stmts[pc][:stmt] = N
        ir.stmts[pc][:type] = Core.Const(N)
        changed = true
    end
    changed || return ir
    for pc in 1:length(ir.stmts)
        st = ir.stmts[pc][:stmt]
        st isa Expr && st.head === :new && st.args[1] isa Core.SSAValue || continue
        t = ir.stmts[st.args[1].id][:type]
        t isa Core.Const && t.val isa DataType && t.val <: NamedTuple || continue
        ir.stmts[pc][:type] = t.val
    end
    return CC.compact!(ir)
end
