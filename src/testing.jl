# Differential testing: run a zero-argument function `f` in Julia and as a compiled
# standalone executable, and compare the results.
#
# Results are reduced to a single `Int` (`Bool`/integers directly, floats via their bit
# pattern) which the executable prints and the harness parses.

using Test: Test

as_int(x::Integer) = Int(x)
as_int(x::Float64) = reinterpret(Int, x)
as_int(x::Float32) = Int(reinterpret(UInt32, x))

module Wrappers using StaticTools end # holds the generated, uniquely named `main` functions
const wrapper_counter = Ref(0)

# A `main(argc, argv)` that runs the statements `body`, with a name that is `prefix` and a number (compiled entry points
# need real names, that are not those of other programs)
function define_main(prefix::Symbol, body::Vector)
    name = Symbol(prefix, wrapper_counter[] += 1)
    Core.eval(Wrappers, :(function $name(argc::Int, argv::Ptr{Ptr{UInt8}})
        $(body...)
        return 0
    end))
    return Base.invokelatest(getproperty, Wrappers, name)
end

# the call `f()` in a `main`: not inlined into it when `isolate` (each case is then a function of its own in the module,
# which `input_dependent_cases` looks at)
case_call(f, isolate::Bool) = isolate ? Expr(:macrocall, Base.var"@noinline", nothing, :($f())) : :($f())

# a `main(argc, argv)` that prints `as_int(f())`
make_main(f; isolate::Bool = false) = define_main(:static_main_, Any[:(printf(c"%ld\n", $as_int($(case_call(f, isolate)))))])

"""
    static_result(f; kwargs...) -> Int

Compile `f()` into a standalone executable, run it, and return its result reduced to an
`Int` (see `as_int`). Throws if compilation, linking or execution fails.
"""
function static_result(f; dir = mktempdir(), kwargs...)
    main = make_main(f)
    exe = Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), dir, string(nameof(main)); kwargs...)
    try
        return parse(Int, readchomp(`$exe`))
    catch err
        crash_backtrace(exe, err) # (what a crash of the program was, in the log of CI, where it can't be run again by hand)
        rethrow()
    end
end

# whether the error is of a program that was stopped by a signal (a crash: a segmentation fault, an illegal instruction,
# an abort), not one that exited with a status, as when it stops with a message of its own (`Dynamic behavior is not
# supported`, an error that is not caught), which says what it is and which is what some tests expect
crashed(err) = err isa ProcessFailedException && any(p -> p.termsignal != 0, err.procs)

# print a backtrace of the program, run again under a debugger, if there is one (`lldb` on macOS, `gdb` on Linux), when
# it crashed (see `crashed`)
function crash_backtrace(exe, err)
    crashed(err) || return
    cmd = if Sys.which("lldb") !== nothing
        # (`-k` runs when the program crashes: in batch mode, nothing that is given with `-o` runs after it does)
        `lldb --batch -o run -k bt -k "register read" -k "disassemble --pc --count 40" -k "memory read --force --size 8 --count 16 \$sp" -- $exe`
    elseif Sys.which("gdb") !== nothing
        # (the address that the program was reading or writing, and the instructions at and before the one that failed:
        # what the crash was, not only where)
        `gdb --batch -ex run -ex bt -ex "p/x \$_siginfo._sifields._sigfault.si_addr" -ex "x/8i \$pc" -ex "x/24i \$pc-64" -ex "info registers" -ex "info proc mappings" -ex "x/8gx \$rsp" $exe`
    else
        return
    end
    try
        @info "The program failed. Backtrace:" exe
        println(stderr, read(ignorestatus(cmd), String))
    catch err
        @info "The program failed. Backtrace not available." err
    end
    return
end

# what `f()` writes to stdout and to stderr in this process (the result, which the compiled `main` prints as the last
# line of the standard output, is returned too). What Julia writes when it runs the code of a test, without its
# deprecation warnings (`Base.depwarn`, which are shown under `--depwarn=yes`, as `Pkg.test` runs Julia, once for each
# place in the code): a program does not show them (see `depwarn` in overrides/system.jl), and whether Julia does depends
# on what ran before, in the same place. The other messages are given to the logger that there is.
struct NoDepwarnLogger{L<:Base.CoreLogging.AbstractLogger} <: Base.CoreLogging.AbstractLogger
    inner::L
end
Base.CoreLogging.shouldlog(l::NoDepwarnLogger, level, _module, group, id) = group !== :depwarn && Base.CoreLogging.shouldlog(l.inner, level, _module, group, id)
Base.CoreLogging.min_enabled_level(l::NoDepwarnLogger) = Base.CoreLogging.min_enabled_level(l.inner)
Base.CoreLogging.catch_exceptions(l::NoDepwarnLogger) = Base.CoreLogging.catch_exceptions(l.inner)
Base.CoreLogging.handle_message(l::NoDepwarnLogger, args...; kwargs...) = Base.CoreLogging.handle_message(l.inner, args...; kwargs...)
without_depwarns(f) = Base.CoreLogging.with_logger(f, NoDepwarnLogger(Base.CoreLogging.current_logger()))

function expected_output(f)
    out_path, out_io = mktemp()
    err_path, err_io = mktemp()
    result = try
        redirect_stdout(out_io) do
            redirect_stderr(err_io) do
                r = without_depwarns(f)
                flush(stdout); flush(stderr)
                Libc.flush_cstdio() # what was written with the streams of libc
                r
            end
        end
    finally
        close(out_io); close(err_io)
    end
    return read(out_path, String) * string(as_int(result), "\n"), read(err_path, String)
end

# how much of the message of a program that failed is given (`TEST_DETAIL=4000`: the places in the code of a call that
# needs the runtime, which the first 300 characters do not reach)
detail_limit() = something(tryparse(Int, get(ENV, "TEST_DETAIL", "")), 300)

"""
    static_status(f; kwargs...) -> (status::Symbol, detail)

Classify how far `f()` gets as a standalone executable: `:compile_error`, `:link_error`,
`:runtime_error`, `:mismatch` or `:ok`. What `f` writes to stdout and to stderr, and what it
returns, must match what it does in Julia. With `inputs = Ref{Union{Missing,Bool}}(missing)`, it is also said
there whether the program of `f` computes something from a value that is only known when it runs (see
[`input_dependent_cases`](@ref)).
"""
function static_status(f; inputs::Union{Nothing,Base.RefValue{Union{Missing,Bool}}} = nothing, kwargs...)
    dir = mktempdir()
    main = make_main(f; isolate = inputs !== nothing)
    exe = try
        # linker failures are reported as a failed process; everything before is "compile"
        inspect = inputs === nothing ? nothing : (mod -> (inputs[] = only(input_dependent_cases(mod, Any[f]))))
        Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), dir, string(nameof(main)); inspect_llvm = inspect, kwargs...)
    catch e
        status = e isa ProcessFailedException || occursin("failed process", sprint(showerror, e)) ?
                 :link_error : :compile_error
        return status, first(sprint(showerror, e), detail_limit())
    end
    err_path = tempname()
    out = try
        read(pipeline(`$exe`; stderr = err_path), String)
    catch e
        crash_backtrace(exe, e) # (what a crash of the program was, in the log of CI, where it can't be run again by hand)
        # (and what the program said before it stopped: a library that it could not open, an error)
        said = isfile(err_path) ? strip(read(err_path, String)) : ""
        return :runtime_error, first(sprint(showerror, e) * (isempty(said) ? "" : " | stderr: " * said), detail_limit())
    end
    # after compiling, which snapshots the state of any global data
    expected, expected_err = expected_output(f)
    err = read(err_path, String)
    out == expected || return :mismatch, "stdout: expected $(repr(expected)), got $(repr(out))"
    err == expected_err || return :mismatch, "stderr: expected $(repr(expected_err)), got $(repr(err))"
    return :ok, ""
end

# A `main` that runs each of `fs` in turn, writing a line with the number of the case (to the standard output, and to
# the standard error) before it, and the result after
function make_batch_main(fs; isolate::Bool = false)
    body = Any[]
    for (i, f) in enumerate(fs)
        push!(body, :(printf(c"@@case %ld@@\n", $i)), :(printf($STDERR, c"@@case %ld@@\n", $i)), :(printf(c"%ld\n", $as_int($(case_call(f, isolate))))))
    end
    return define_main(:static_batch_, body)
end

# what each of `fs` writes in this process, in the same form as the batch program writes it (see `make_batch_main`): the
# text of the standard output and of the standard error for each
function expected_batch(fs)
    out_path, out_io = mktemp()
    err_path, err_io = mktemp()
    try
        redirect_stdout(out_io) do
            redirect_stderr(err_io) do
                for (i, f) in enumerate(fs)
                    print(stdout, "@@case ", i, "@@\n"); print(stderr, "@@case ", i, "@@\n")
                    r = without_depwarns(f)
                    print(stdout, as_int(r), "\n")
                    flush(stdout); flush(stderr)
                    Libc.flush_cstdio() # what was written with the streams of libc
                end
            end
        end
    finally
        close(out_io); close(err_io)
    end
    return split_batch(read(out_path, String), length(fs)), split_batch(read(err_path, String), length(fs))
end

# the text of each case in the output of a batch program
function split_batch(text::AbstractString, n::Int)
    parts = fill("", n)
    marks = collect(eachmatch(r"@@case (\d+)@@\n", text))
    for (k, m) in enumerate(marks)
        i = parse(Int, m.captures[1])
        stop = k < length(marks) ? marks[k+1].offset - 1 : lastindex(text)
        1 <= i <= n && (parts[i] = text[m.offset+ncodeunits(m.match):stop])
    end
    return parts
end

"""
    static_status_batch(fs; inputs = nothing, kwargs...) -> Vector{Tuple{Symbol,String}}

[`static_status`](@ref) of each zero-argument function in `fs`, for independent cases. They are compiled as **one**
program that runs them in turn, which is much faster than a program each; any case that is not `:ok` in it is compiled
again on its own, so that each gets the status it would have alone.

With `inputs` (a `Vector{Union{Missing,Bool}}` of the length of `fs`), each element is set to whether that case's program
computes anything from a value only known when it runs (see [`input_dependent_cases`](@ref)), or `missing` if not known.
"""
function static_status_batch(fs::AbstractVector; inputs::Union{Nothing,AbstractVector} = nothing, kwargs...)
    n = length(fs)
    inputs === nothing || fill!(inputs, missing)
    single(i) = if inputs === nothing
        static_status(fs[i]; kwargs...)
    else
        r = Ref{Union{Missing,Bool}}(missing)
        status = static_status(fs[i]; inputs = r, kwargs...)
        inputs[i] = r[]
        status
    end
    n <= 1 && return Tuple{Symbol,String}[single(i) for i in 1:n]
    mismatched = Int[]
    try
        main = make_batch_main(fs; isolate = inputs !== nothing)
        inspect = inputs === nothing ? nothing : (mod -> copyto!(inputs, input_dependent_cases(mod, fs)))
        exe = Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(main)); inspect_llvm = inspect, kwargs...)
        err_path = tempname()
        out = read(pipeline(`$exe`; stderr = err_path), String)
        err = read(err_path, String)
        expected_out, expected_err = expected_batch(fs)
        got_out, got_err = split_batch(out, n), split_batch(err, n)
        mismatched = [i for i in 1:n if got_out[i] != expected_out[i] || got_err[i] != expected_err[i]]
    catch e
        @debug "a batch of cases was not run as one program; they are compiled one by one" exception = (e, catch_backtrace())
        mismatched = collect(1:n) # (it does not compile, or crashes: which of them is found by compiling each)
    end
    return Tuple{Symbol,String}[i in mismatched ? single(i) : (:ok, "") for i in 1:n]
end

## Whether a case computes something when it runs

"""
    input_dependent_cases(mod::LLVM.Module, fs) -> Vector{Bool}

For each of the zero-argument functions `fs`, whether its code in the module `mod` (each is a function of its own there:
see `make_batch_main` with `isolate`) computes something from a value that is only known when the program runs: the
time, which `opaque` in the tests is made of (`time_ns()` is a call of `clock_gettime`, which writes into memory), and
the entropy of the system (`getentropy`), which the random numbers start from. Values are followed from what is read of
that memory through the instructions that use them, what is stored and read again (in a slot of the stack or an object
of the binary, which are told apart, and the rest of memory, which is not), the arguments of the functions that they are
given to, and what functions return. A case does if, in the code from which it can still return normally, it stores such
a value, returns one, gives one to a call, or branches on one where both ways can return. A case whose function is not
in the module (the compiler found what it returns, and the call is gone) does not. It also does if its own code reads
memory that is not of its own stack and uses what it reads (a global that is not `const`, a mutable object that it
captured: what is in them is known only when the program runs; a read of a constant is folded by LLVM), calls a function
of the program (whose code runs then, whatever its arguments are: `print` of a number), or uses what a function of a
library or of the system gives (`stat` of a file). A case that does neither is one whose program is only the answer that
the compiler found: the test of it tests the compiler's constant folding, and not the code that it is about.
"""
function input_dependent_cases(mod::LLVM.Module, fs)
    found = Bool[]
    for f in fs
        fns = case_functions(mod, f)
        push!(found, !isempty(fns) && computes_from_input(values_from_input(fns)))
    end
    return found
end

# What is found of the values that come from the time and the entropy in the code that the functions `roots` reach (the
# functions that they call, and those that those call): the values, the memory that holds them, the arguments that are
# given them, the functions that return them; and the functions that are looked at. For each case on its own, so that a
# function that two cases call is given what one of them gives it only when that case is looked at.
struct InputValues
    roots::Vector{LLVM.Function}
    tainted::Set{Ptr{Cvoid}}    # values
    memory::Set{Ptr{Cvoid}}     # the stack slots (allocas) and the constant objects that hold such a value: known by their address, which is the same in all the code
    heap::Base.RefValue{Bool}   # whether the rest of memory (what is allocated, reached through pointers that are loaded or given) holds one: it is not told apart
end

llvm_key(v) = Ptr{Cvoid}(v.ref)
function pointer_base(v)
    for _ in 1:32
        if v isa LLVM.GetElementPtrInst || v isa LLVM.BitCastInst || v isa LLVM.AddrSpaceCastInst
            v = LLVM.operands(v)[1]
        elseif v isa LLVM.ConstantExpr && LLVM.API.LLVMGetConstOpcode(v) in (LLVM.API.LLVMGetElementPtr, LLVM.API.LLVMBitCast, LLVM.API.LLVMAddrSpaceCast)
            v = LLVM.operands(v)[1]
        else
            break
        end
    end
    return v
end
exact_memory(v) = v isa LLVM.AllocaInst || v isa LLVM.Constant # (a slot of the stack, or an object of the binary: its address is a constant)
is_pointer(v) = LLVM.value_type(v) isa LLVM.PointerType
input_source(name) = occursin("clock_gettime", name) || occursin("gettimeofday", name) || occursin("mach_absolute_time", name) || occursin("getentropy", name)
has_input(s::InputValues, v) = llvm_key(v) in s.tainted
function holds_input(s::InputValues, p) # (whether what a pointer points to holds one)
    b = pointer_base(p)
    return exact_memory(b) ? llvm_key(b) in s.memory : s.heap[]
end
reaches_input(s::InputValues, v) = has_input(s, v) || (is_pointer(v) && holds_input(s, v))

function values_from_input(roots::Vector{LLVM.Function})
    # (the functions that are reached)
    fns = LLVM.Function[]
    seen = Set{Ptr{Cvoid}}()
    todo = copy(roots)
    while !isempty(todo)
        fn = pop!(todo)
        llvm_key(fn) in seen && continue
        push!(seen, llvm_key(fn))
        push!(fns, fn)
        for bb in LLVM.blocks(fn), inst in LLVM.instructions(bb)
            inst isa LLVM.CallInst || continue
            callee = LLVM.called_operand(inst)
            callee isa LLVM.Function && !LLVM.isdeclaration(callee) && push!(todo, callee)
        end
    end
    s = InputValues(roots, Set{Ptr{Cvoid}}(), Set{Ptr{Cvoid}}(), Ref(false))
    params = Set{Tuple{Ptr{Cvoid},Int}}() # (function, argument) that is given one
    returns = Set{Ptr{Cvoid}}()           # functions that return one
    changed = Ref(true)
    add!(set, x) = (x in set || (push!(set, x); changed[] = true); nothing)
    function hold!(p) # (what `p` points to now holds one)
        b = pointer_base(p)
        exact_memory(b) ? add!(s.memory, llvm_key(b)) : (s.heap[] || (s.heap[] = true; changed[] = true))
        return
    end
    while changed[]
        changed[] = false
        for fn in fns
            for (i, p) in enumerate(LLVM.parameters(fn))
                (llvm_key(fn), i) in params && add!(s.tainted, llvm_key(p))
            end
            for bb in LLVM.blocks(fn), inst in LLVM.instructions(bb)
                ops = LLVM.operands(inst)
                if inst isa LLVM.LoadInst
                    reaches_input(s, ops[1]) && add!(s.tainted, llvm_key(inst))
                elseif inst isa LLVM.StoreInst
                    has_input(s, ops[1]) && hold!(ops[2])
                elseif inst isa LLVM.CallInst
                    callee = LLVM.called_operand(inst)
                    name = callee isa LLVM.Function ? LLVM.name(callee) : ""
                    args = ops[1:end-1]
                    if input_source(name)
                        LLVM.value_type(inst) isa LLVM.VoidType || add!(s.tainted, llvm_key(inst)) # (`mach_absolute_time` returns it)
                        for a in args
                            is_pointer(a) && hold!(a)
                        end
                    elseif startswith(name, "llvm.memcpy") || startswith(name, "llvm.memmove")
                        reaches_input(s, args[2]) && hold!(args[1])
                    elseif startswith(name, "llvm.memset")
                        has_input(s, args[2]) && hold!(args[1])
                    elseif callee isa LLVM.Function && !LLVM.isdeclaration(callee)
                        for (i, a) in enumerate(args)
                            reaches_input(s, a) && add!(params, (llvm_key(callee), i))
                        end
                        llvm_key(callee) in returns && add!(s.tainted, llvm_key(inst))
                    elseif any(a -> reaches_input(s, a), args) || has_input(s, callee)
                        LLVM.value_type(inst) isa LLVM.VoidType || add!(s.tainted, llvm_key(inst))
                    end
                elseif inst isa LLVM.RetInst
                    !isempty(ops) && has_input(s, ops[1]) && add!(returns, llvm_key(fn))
                elseif !(LLVM.value_type(inst) isa LLVM.VoidType) && any(o -> has_input(s, o), ops)
                    add!(s.tainted, llvm_key(inst))
                end
            end
        end
    end
    return s
end

# Whether the case computes something with such a value that it gives on: in its own functions (`s.roots`), stores one,
# returns one, gives one to a call, or decides by one which way to go. Only in the blocks from which the function can
# still return (the others are the paths of an error: a check that a value is in range, which does not change the answer
# when it passes), and a branch only where both ways can.
function computes_from_input(s::InputValues)
    for fn in s.roots
        blocks = collect(LLVM.blocks(fn))
        index = Dict(llvm_key(bb) => i for (i, bb) in enumerate(blocks))
        succs = [Int[index[llvm_key(t)] for t in LLVM.successors(LLVM.terminator(bb)) if haskey(index, llvm_key(t))] for bb in blocks]
        live = Bool[LLVM.terminator(bb) isa LLVM.RetInst for bb in blocks]
        grew = true
        while grew
            grew = false
            for i in eachindex(blocks)
                live[i] || !any(j -> live[j], succs[i]) || (live[i] = true; grew = true)
            end
        end
        for (i, bb) in enumerate(blocks)
            live[i] || continue
            for inst in LLVM.instructions(bb)
                ops = LLVM.operands(inst)
                if inst isa LLVM.RetInst
                    !isempty(ops) && has_input(s, ops[1]) && return true
                elseif inst isa LLVM.LoadInst
                    # (a read of memory that is not of the case's own stack, whose value is used: of a global that is
                    # not `const`, of a mutable object (a `Matrix` that the case captured), of what the case made. What
                    # is in it is known only when the program runs: a read of a constant is folded by LLVM, and is not
                    # here)
                    !(pointer_base(ops[1]) isa LLVM.AllocaInst) && !isempty(LLVM.uses(inst)) && return true
                elseif inst isa LLVM.StoreInst
                    has_input(s, ops[1]) && return true
                elseif inst isa LLVM.CallInst
                    callee = LLVM.called_operand(inst)
                    # (not the intrinsics: what a `memcpy` moves is followed to where it is used; and the memory that is
                    # cleared before the time is written into it is the same memory, as the order of the code is not
                    # looked at)
                    (callee isa LLVM.Function && (input_source(LLVM.name(callee)) || startswith(LLVM.name(callee), "llvm."))) && continue
                    # (a function of the program: its code runs when the program does, `print` of a number, `show` of a
                    # matrix, whatever the arguments are. One of a library or of the system, whose result is used: what
                    # it gives is known only then, `stat` of a file, a match of a regex. Not one whose result is not
                    # used, with arguments that are constants: `printf` of a text that the compiler made, which is the
                    # answer)
                    callee isa LLVM.Function && !LLVM.isdeclaration(callee) && return true
                    !(LLVM.value_type(inst) isa LLVM.VoidType) && !isempty(LLVM.uses(inst)) && return true
                    # (a value, or a pointer to memory that holds one that is known: `heap` is everything else, and many
                    # calls are given a pointer of it)
                    any(a -> has_input(s, a) || (is_pointer(a) && exact_memory(pointer_base(a)) && llvm_key(pointer_base(a)) in s.memory), ops[1:end-1]) && return true
                elseif inst isa LLVM.BrInst || inst isa LLVM.SwitchInst
                    any(o -> has_input(s, o), ops) && count(j -> live[j], succs[i]) >= 2 && return true
                end
            end
        end
    end
    return false
end

# the functions of the module that are the code of `f` (`julia_<name>_<number>`, the name of its method: that of the
# function, or of the closure, `#8`, as `_8`)
function case_functions(mod::LLVM.Module, f)
    prefix = "julia_" * replace(string(nameof(f)), '#' => '_') * "_"
    return [fn for fn in LLVM.functions(mod) if !LLVM.isdeclaration(fn) && startswith(LLVM.name(fn), prefix) && all(isdigit, LLVM.name(fn)[ncodeunits(prefix)+1:end])]
end

"""
    @static_test f()

Test that the compiled standalone executable of the zero-argument call `f()` gives the same
result as Julia does.
"""
macro static_test(ex)
    quote
        Test.@test static_result(() -> $(esc(ex))) == as_int($(esc(ex)))
    end
end

# The symbols that a program may leave to the C library: the functions that `ccall` by name resolves to it
# (`Runtime.LIBC_FUNCTIONS`), and the ones that the runtime and the files call
const LIBC_SYMBOLS = union(Runtime.LIBC_FUNCTIONS, ["printf", "fprintf", "sigsetjmp", "siglongjmp", "fopen", "fclose", "fgetc", "ungetc", "fseek", "ftell", "getc", "putc",
                                                    "__stdoutp", "__stderrp", "__stdinp", "stdout", "stderr", "stdin"])

"""
    undefined_symbols(f, types; allow = LIBC_SYMBOLS) -> Vector{String}

Names of the functions and global variables that the compiled code of `f(types...)` uses but does not define
(excluding LLVM intrinsics and the symbols in `allow`). A nonempty result means the binary
depends on something other than libc, such as libjulia, and will not link or run standalone.
"""
function undefined_symbols(f, types; allow = LIBC_SYMBOLS, kwargs...)
    LLVM = StaticCompiler.LLVM
    try
        Base.invokelatest() do
            StaticCompiler.GPUCompiler.JuliaContext() do ctx
                mod = static_llvm_module(f, Base.to_tuple_type(types); kwargs...)
                try
                    names = [LLVM.name(x) for x in Iterators.flatten((LLVM.functions(mod), LLVM.globals(mod))) if LLVM.isdeclaration(x)]
                    return sort!(filter(n -> !startswith(n, "llvm.") && n ∉ allow, names))
                finally
                    LLVM.dispose(mod)
                end
            end
        end
    catch e
        e isa UnsupportedCodeError || rethrow()
        # what strict mode rejects
        names = String[first(d) for d in e.dynamic]
        isempty(e.pointers) || push!(names, "<$(length(e.pointers)) reference(s) to Julia objects by address>")
        return sort!(names)
    end
end

# `undefined_symbols` of the zero-argument `f` wrapped as an executable entry point
undefined_symbols(f; kwargs...) = undefined_symbols(make_main(f), (Int, Ptr{Ptr{UInt8}}); kwargs...)

const ALLOCATORS = Set(["gpu_gc_pool_alloc", "julia.gc_alloc_bytes", "jl_alloc_genericmemory_unchecked",
                        "ijl_alloc_string", "ijl_box_int64", "ijl_box_uint64", "ijl_box_int32", "ijl_box_uint32", "ijl_box_char",
                        "ijl_box_int8", "ijl_box_uint8", "ijl_box_int16", "ijl_box_uint16", "ijl_box_float32", "ijl_box_float64"])

"""
    allocation_sites(f, types) -> Int

The number of places in the compiled code of `f(types...)` that allocate heap memory (arrays, strings, boxed values,
exceptions, ...). A program without the collector (see `gc` in [`compile_executable`](@ref)) never frees what these
places allocate. Zero means the function never allocates. Allocations on paths that never run (a `throw` that is never
reached) are counted too: this is an upper bound.
"""
function allocation_sites(f, types; kwargs...)
    LLVM = StaticCompiler.LLVM
    Base.invokelatest() do
        StaticCompiler.GPUCompiler.JuliaContext() do ctx
            # (before the runtime is linked in: the allocation functions are inlined there, when the collector is used,
            # and then they are not calls any more)
            mod = static_llvm_module(f, Base.to_tuple_type(types); strict = false, llvm_postprocess = mod -> nothing, kwargs...)
            try
                n = 0
                for fn in LLVM.functions(mod), bb in LLVM.blocks(fn), inst in LLVM.instructions(bb)
                    inst isa LLVM.CallInst || continue
                    callee = LLVM.called_operand(inst)
                    callee isa LLVM.Function && LLVM.name(callee) in ALLOCATORS && (n += 1)
                end
                return n
            finally
                LLVM.dispose(mod)
            end
        end
    end
end
