using StaticRuntime
using Documenter

DocMeta.setdocmeta!(StaticRuntime, :DocTestSetup, :(using StaticRuntime); recursive=true)

makedocs(;
    modules=[StaticRuntime, StaticRuntime.Runtime],
    authors="C. Brenhin Keller",
    repo="https://github.com/brenhinkeller/StaticRuntime.jl/blob/{commit}{path}#{line}",
    sitename="StaticRuntime.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        edit_link="main",
        canonical="https://brenhinkeller.github.io/StaticRuntime.jl",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
        "Basic Usage" => "usage.md",
        "The Runtime" => "runtime.md",
        "Binary size and performance" => "performance.md",
        "Compiling: overrides, passes, and inference" => "compiling.md",
        "Supported libraries and packages" => "support.md",
        "Known Limitations" => "limits.md",
        "API Reference" => "reference.md",
    ],
)

deploydocs(;
    repo="github.com/brenhinkeller/StaticRuntime.jl",
    devbranch="main",
)
