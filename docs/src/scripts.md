# Compiling scripts

`compile_script(path)` and `compile_script_string(code)` compile a `.jl` script to an executable that does what `julia script.jl args...` does:

```julia
using StaticRuntime
compile_script("analysis.jl", "build", "analysis")   # build/analysis
```

`dir` (default: the current directory) and `name` (default: the name of the file) say where the executable goes; the other keywords are those of `compile_executable`. The program has `ARGS`, the arguments of the command line (`Base.ARGS` is not supported). `PROGRAM_FILE`, `@__FILE__` and `@__DIR__` are those of the script when it was compiled. If the script ends with `@main` (or defines `function main(args)` with `@main`), `main(ARGS)` runs after the top-level code and its result is the exit status. `exit(n)` works.

## What is done when compiling

The script is split in order:

* **Definitions** (`using`, `import`, `struct`, functions, macros, `const`, `include("other.jl")`) are evaluated when compiling, in a module of their own. Macros are expanded first, so `@kwdef` and `@enum` work.
* **Initial values** (`evaluate = :init`, the default): a variable that is made of literals, collections and ranges and comprehensions of them, arithmetic, and the functions of Base that have no effects (`sort`, `Dict`, `string`, `join`, ...) is worked out when compiling and is in the program when it starts. This goes on only until the first statement that does anything else (printing, reading a file, `rand()`, a call of a function of the script): after it everything is done when the program runs, in the order of the script. `evaluate = :definitions` does only the definitions.
* `@comptime x = f(3)` forces a statement to be done when compiling, and `@runtime stmt` forces one to wait for the program. Define `macro compile_time(ex) esc(ex) end` and `macro runtime(ex) esc(ex) end` if the script also has to run in Julia.

## Variables

What is left of the script is the body of one function, so the variables of the script are its **locals**, which the compiler can make fast. A variable that a function of the script mentions (a counter, a setting, a cache) can't be a local, since a function doesn't see the locals of another: it becomes a **global of the module**. A global of that kind has no declared type, and a call on it can fail to compile (`global n::Int` says its type). `globals = :error` refuses a script that has such variables, so that all of it is local.

A loop at the top that assigns a variable of the script *without* `global` updates that variable, as in the REPL or in a function (`scope = :soft`, the default). In a file Julia instead makes a new variable of the loop and warns that it is ambiguous, so `total = 0; for i in 1:3; total += i; end` fails there with `UndefVarError`, and a loop that meant a fresh variable of its own would print the old value afterwards. `scope = :hard` refuses such a loop, with a message that says to write `global x` or to use another name; write `local x` in the loop for a variable of its own in either mode.

## Not supported

Definitions inside `if` or `for`, `eval` and `Meta.parse` of strings made when the program runs, `Pkg`, and the other limits of the package (see [Limits](limits.md)). The packages that the script loads with `using` have to be in the environment that compiles it.
