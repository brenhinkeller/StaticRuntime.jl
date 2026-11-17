# UnicodePlots in a program (plots written to the terminal). What the package writes with the types of values that are only known when it runs is written again here with the types known.

module StaticRuntimeUnicodePlotsExt

using StaticRuntime: @device_override
using UnicodePlots: UnicodePlots

# The keywords of a plot are split, by name, into those of the plot (`PLOT_KEYS`) and the others, with `filter` of the keywords: of a `NamedTuple`, whose names are in its type, `filter` is a value that is made when the
# program runs, with the names that are left in it (a `NamedTuple` of a type that the compiler does not know: the call with it is the one that is `Union{}`). The names are in the type, so the split is done by them, when compiling.
# The keywords that are given to a call are a `Pairs` that has `Nothing` for its iterator (`Pairs{Symbol,V,Nothing,NamedTuple}`), which `NamedTuple(pairs)` and the merge of a call with `kw...` take the `NamedTuple` out of, with its type;
# what `pairs(nt)` gives has the keys there, and for that `NamedTuple(pairs)` is a value made when the program runs, of a type that the compiler does not know. The `Pairs` of keywords are made here as the call makes them.
function kw_pairs_expr(::Type{NT}, names::Tuple) where {NT<:NamedTuple}
    values = Expr(:tuple, (:(getfield(data, $(QuoteNode(n)))) for n in names)...)
    return :(kw_pairs($names, $values))
end

@inline function kw_pairs(names::Tuple, values::Tuple)
    nt = NamedTuple{names}(values)
    return Base.Pairs{Symbol,eltype(nt),Nothing,typeof(nt)}(nt, nothing)
end

@generated function split_named(data::NT) where {NT<:NamedTuple}
    names = fieldnames(NT)
    plot = Tuple(n for n in names if n in UnicodePlots.PLOT_KEYS)
    other = Tuple(n for n in names if !(n in UnicodePlots.PLOT_KEYS))
    return Expr(:tuple, kw_pairs_expr(NT, plot), kw_pairs_expr(NT, other))
end

@device_override UnicodePlots.split_plot_kw(kw::Base.Pairs{Symbol,V,I,<:NamedTuple}) where {V,I} = split_named(getfield(kw, :data))

# `filter(f, kw)` of the keywords of a call (`callable(hist; info, filter(p -> p.first ≢ :nbins, kw)...)`) is the `filter` of a dictionary, a `Dict` made when the program runs, and what is splatted into the keywords of another call is then
# a `NamedTuple` that the compiler does not know the names of. The names are in the type of the keywords, so `f` is called with each of them as a constant (a `Pair` of the name and the value), and what it says is known when compiling if `f` depends on
# the name only (the usual predicate): what is kept is then in the type. What is given back is the `Pairs` of the kept ones, which is iterated and splatted as the `Dict` was (it is not one that can be changed).
@generated function filter_named(f, data::NT) where {NT<:NamedTuple}
    names = fieldnames(NT)
    block = Expr(:block)
    keep = Symbol[]
    for (i, n) in enumerate(names)
        k = Symbol(:keep, i)
        push!(keep, k)
        push!(block.args, :($k = f(Pair($(QuoteNode(n)), getfield(data, $(QuoteNode(n)))))::Bool))
    end
    kept_names = Expr(:tuple, (Expr(:..., :($(keep[i]) ? ($(QuoteNode(n)),) : ())) for (i, n) in enumerate(names))...)
    kept_values = Expr(:tuple, (Expr(:..., :($(keep[i]) ? (getfield(data, $(QuoteNode(n))),) : ())) for (i, n) in enumerate(names))...)
    push!(block.args, :(kw_pairs($kept_names, $kept_values)))
    return block
end

@device_override Base.@constprop :aggressive @inline function Base.filter(f, kw::Base.Pairs{Symbol,V,I,<:NamedTuple}) where {V,I}
    return filter_named(f, getfield(kw, :data))
end

# `histogram` takes the dimensions of size one out of the array (`dropdims(x; dims = Tuple(filter(d -> size(x, d) == 1, 1:ndims(x))))`): the number of them is in the number of dimensions of the array that it gives, which is a value that
# is only known when the program runs (a tuple of a length that depends on the sizes). A vector keeps its dimension here (what the package makes of one that has one element is a plot of a single value, not of an array that has no
# dimensions), and the rest is as the package has it.
@device_override function UnicodePlots.histogram(x::AbstractVector; closed = :left, vertical = false, stats = true, kw...)
    len = length(x)
    nbins = get(kw, :nbins, UnicodePlots.sturges(len))
    hist = UnicodePlots.fit(UnicodePlots.Histogram, x; closed, nbins)
    info = if vertical && stats
        digits = 2
        mx, Mx = extrema(x)
        μ = sum(x) / len
        σ = √(sum((x .- μ) .^ 2) / len)
        (
            "μ ± σ: " *
                lpad(round(μ; digits), digits + 1) * " ± " *
                lpad(round(σ; digits), digits + 1)
        )
    else
        ""
    end
    callable = vertical ? UnicodePlots.vertical_histogram : UnicodePlots.horizontal_histogram
    return callable(hist; info, filter(p -> p.first ≢ :nbins, kw)...)
end

# `heatmap` of a matrix of numbers. The original gives the limits of the colors as `(0, 0)` and then the extrema of the matrix (integers, then of the type of the elements), and keeps the function that makes the colors in a variable that is
# one of two functions (that of the colors of an image, or that of the color map), so that the keywords of the plot are a `NamedTuple` of a type that has unions of types in it, and merging it with the keywords of the call (`filter(...)...`) gives a
# `NamedTuple` that the compiler does not know the type of. Here the limits are `Float64`s and the function is the color map's (the rest is as the package has it: for matrices of numbers only; an image is not).
@device_override function UnicodePlots.heatmap(
        A::AbstractMatrix{T};
        xlim = UnicodePlots.KEYWORDS.xlim,
        ylim = UnicodePlots.KEYWORDS.ylim,
        zlim = UnicodePlots.KEYWORDS.zlim,
        yoffset::Number = 0.0,
        xoffset::Number = 0.0,
        out_stream::Union{Nothing, IO} = nothing,
        height::Union{Nothing, Integer} = nothing,
        width::Union{Nothing, Integer} = nothing,
        margin::Integer = UnicodePlots.KEYWORDS.margin,
        padding::Integer = UnicodePlots.KEYWORDS.padding,
        colormap = UnicodePlots.KEYWORDS.colormap,
        yfact::Union{Nothing, Number} = nothing,
        xfact::Union{Nothing, Number} = nothing,
        fix_ar::Bool = UnicodePlots.KEYWORDS.fix_ar,
        labels::Bool = UnicodePlots.KEYWORDS.labels,
        array::Bool = false,
        kw...,
    ) where {T <: Real}
    pkw, okw = UnicodePlots.split_plot_kw(kw)
    UnicodePlots.warn_on_lost_kw(okw)

    nrows, ncols = size(A)

    Y = if yfact ≡ nothing
        collect(1:nrows)
    else
        collect(0:(nrows - 1)) .* yfact
    end .+ yoffset
    X = if xfact ≡ nothing
        collect(1:ncols)
    else
        collect(0:(ncols - 1)) .* xfact
    end .+ xoffset

    ylim = UnicodePlots.autolims(ylim, Y)
    xlim = UnicodePlots.autolims(xlim, X)

    subset(lims, vec) = begin
        first = findfirst(x -> x ≥ lims[1], vec)
        last = findlast(x -> x ≤ lims[2], vec)
        (first ≡ nothing || last ≡ nothing) ? (1:0) : (first:last)
    end

    yrange = subset(ylim, Y)
    xrange = subset(xlim, X)
    Y = Y[yrange]
    X = X[xrange]
    A = A[yrange, xrange]

    nrows = ceil(Int, (ylim[2] - ylim[1]) / something(yfact, 1)) + 1
    ncols = ceil(Int, (xlim[2] - xlim[1]) / something(xfact, 1)) + 1

    mi::Float64 = 0.0
    ma::Float64 = 0.0
    has_extrema = false
    if !isempty(A)
        mi, ma = UnicodePlots.nanless_extrema(A)
        has_extrema = true
    end
    if !UnicodePlots.is_auto(zlim)
        has_extrema || throw(ArgumentError("`zlim` cannot be set when the element type is $T"))
        mi, ma = zlim
    end

    callback = UnicodePlots.colormap_callback(colormap)

    data_ar = ncols / nrows  # data aspect ratio

    max_width = if width ≡ nothing
        height ≡ nothing ? 0 : ceil(Int, height * data_ar)
    else
        width
    end
    max_height = if height ≡ nothing
        width ≡ nothing ? 0 : ceil(Int, width / data_ar)
    else
        height
    end

    # `2nrows`: compensate nrows(c::HeatmapCanvas) = div(size(c.grid, 1) + 1, 2)
    height, width, max_height, max_width = UnicodePlots.get_canvas_dimensions_for_matrix(
        UnicodePlots.HeatmapCanvas,
        2nrows,
        ncols,
        max_height,
        max_width,
        height,
        width,
        margin,
        padding,
        out_stream,
        fix_ar,
    )

    colorbar = has_extrema && if height < 7
        # for small plots, don't show colorbar by default
        get(pkw, :colorbar, false)
    else
        # show colorbar by default, unless set to false, or `labels = false`
        get(pkw, :colorbar, labels)
    end

    xs = length(X) > 0 ? [first(X), last(X)] : zeros(2)
    ys = length(Y) > 0 ? [first(Y), last(Y)] : zeros(2)

    plot = UnicodePlots.Plot(
        xs,
        ys,
        nothing,
        UnicodePlots.HeatmapCanvas;
        colorbar,
        ylim,
        xlim,
        labels,
        height,
        width,
        margin,
        colorbar_lim = (mi, ma),
        colormap = callback,
        min_height = 1,
        min_width = 1,
        yflip = array,
        grid = false,
        filter(x -> x.first ≢ :colorbar, pairs(pkw))...,
    )

    for row in eachindex(Y)
        color = UnicodePlots.ColorType[UnicodePlots.ansi_color(callback(x, mi, ma)) for x in view(A, row, :)]
        blend = UnicodePlots.blend_colors.(Ref(plot.graphics), color)
        UnicodePlots.points!(plot, X, fill(Y[row], length(X)), color, blend)
    end
    return plot
end

# A heatmap is written a row at a time, with the color of the cell above as the keyword `bgcol` of `print_color`: a color, or `missing` for the first row (`bgcol = row > 1 ? colors[row - 1, col] : missing`). A keyword that has a value of one of two types is a
# `NamedTuple` whose type has a union in it, which a method cannot be made for (it is of the type `NamedTuple` when it is compiled, and the keyword is read from it by a call of the runtime). Each of the two calls is made with the type of its own.
@device_override function UnicodePlots.print_row(io::IO, _, print_color, c::UnicodePlots.HeatmapCanvas, row::Integer)
    1 ≤ row ≤ UnicodePlots.nrows(c) || throw(ArgumentError("`row` out of bounds: $row"))
    row *= UnicodePlots.y_pixel_per_char(UnicodePlots.HeatmapCanvas)

    # extend the plot upwards by half a row
    isodd(size(c.grid, 1)) && (row -= 1)

    for col in 1:UnicodePlots.ncols(c)
        # for odd numbers of rows, only print the foreground for the top row
        if row > 1
            print_color(io, c.colors[row, col], UnicodePlots.HALF_BLOCK; bgcol = c.colors[row - 1, col])
        else
            print_color(io, c.colors[row, col], UnicodePlots.HALF_BLOCK)
        end
    end

    return nothing
end

# `polarplot`: the limit of the radius is `(0, 0)` (two integers) when it is not given, and the largest radius is then the maximum of the data or the integer that was given: one of two types, which makes the limits of the axes, the keywords of the plot and
# the grid that is drawn have types that are unions. The limits are `Float64`s here, and the rest is as the package has it (for a vector of radii: a function is not).
@device_override function UnicodePlots.polarplot(θ::AbstractVector, r::AbstractVector; rlim = (0, 0), kw...)
    pkw, okw = UnicodePlots.split_plot_kw(kw)

    max_r = Float64(last(UnicodePlots.is_auto(rlim) ? extrema(r) : rlim))
    lims = x = y = [-max_r, +max_r]
    plot = UnicodePlots.Plot(
        x,
        y;
        xlim = lims,
        ylim = lims,
        grid = false,
        border = :none,
        xticks = false,
        yticks = false,
        blend = false,
        pkw...,
    )
    return UnicodePlots.polarplot!(plot, θ, r; rlim, okw...)
end

@device_override function UnicodePlots.polarplot!(
        plot::UnicodePlots.Plot{<:UnicodePlots.Canvas},
        θ::AbstractVector,
        r::AbstractVector;
        rlim = (0, 0),
        degrees = true,
        num_rad_lab = 3,
        ang_rad_lab = π / 4,
        scatter = false,
        kw...,
    )
    mr::Float64, Mr::Float64 = UnicodePlots.is_auto(rlim) ? extrema(r) : rlim

    # grid
    theta = range(0, 2π; length = 360)
    grid_color = UnicodePlots.BORDER_COLOR[]
    UnicodePlots.lineplot!(plot, Mr * cos.(theta), Mr * sin.(theta); color = grid_color)

    for theta in 0:(π / 4):(2π)
        UnicodePlots.lineplot!(plot, [mr, Mr] .* cos(theta), [mr, Mr] .* sin(theta); color = grid_color)
    end

    # user data
    (scatter ? UnicodePlots.scatterplot! : UnicodePlots.lineplot!)(plot, r .* cos.(θ), r .* sin.(θ); kw...)

    # labels
    row = ceil(Int, UnicodePlots.nrows(plot.graphics) / 2)
    UnicodePlots.label!(plot, :r, row, degrees ? "0°" : "0"; color = grid_color)
    UnicodePlots.label!(plot, :t, degrees ? "90°" : "π / 2"; color = grid_color)
    UnicodePlots.label!(plot, :l, row, degrees ? "180°" : "π"; color = grid_color)
    UnicodePlots.label!(plot, :b, degrees ? "270°" : "3π / 2"; color = grid_color)

    for r in range(mr, Mr; length = num_rad_lab)
        UnicodePlots.annotate!(
            plot,
            r * cos(ang_rad_lab),
            r * sin(ang_rad_lab),
            isinteger(r) ? string(round(Int, r)) : UnicodePlots.@sprintf("%.1f", r);
            color = grid_color,
        )
    end
    return plot
end

# `surfaceplot` of the values of a function (or of a matrix) on a grid of two vectors, with the scale of the heights that is the default (`:identity`: `zscale` is a symbol, a function or a tuple, and the height and the matrix of the points are
# of a type for each). The type of the limits of the colors is one of two (`(0, 0)` as integers, or the extrema of the heights), so they are `Float64`s. The rest is the package's.
@device_override function UnicodePlots.surfaceplot(
        x::AbstractVector,
        y::AbstractVector,
        A::Union{Function, AbstractMatrix};
        zscale::Symbol = :identity,
        canvas::Type = UnicodePlots.KEYWORDS.canvas,
        colormap = UnicodePlots.KEYWORDS.colormap,
        kw...,
    )
    zscale ≡ :identity || error("only the `:identity` `zscale` of a surface plot is supported in a compiled program")
    pkw, okw = UnicodePlots.split_plot_kw(kw)
    X, Y = UnicodePlots.meshgrid(x, y)
    H = A isa Function ? A.(X, Y) : A

    ex, ey = map(collect ∘ extrema, (x, y))
    eh = collect(UnicodePlots.nanless_extrema(H))
    ez = eh
    Z = H

    plot = UnicodePlots.Plot(
        ex,
        ey,
        ez,
        canvas;
        projection = UnicodePlots.KEYWORDS.projection,
        labels = false,
        colormap,
        pkw...,
    )
    return UnicodePlots.surfaceplot!(plot, X, Y, Z, H; colormap, okw...)
end

@device_override function UnicodePlots.surfaceplot!(
        plot::UnicodePlots.Plot{<:UnicodePlots.Canvas},
        X::AbstractMatrix,
        Y::AbstractMatrix,
        Z::AbstractMatrix,
        H::Union{AbstractMatrix, Nothing} = nothing;
        color::UnicodePlots.UserColorType = nothing,
        colormap = UnicodePlots.KEYWORDS.colormap,
        lines::Bool = false,
        zlim = UnicodePlots.KEYWORDS.zlim,
        kw...,
    )
    lines && error("the mesh lines of a surface plot (`lines = true`) are not supported in a compiled program")
    H = something(H, Z)
    length(X) == length(Y) == length(Z) == length(H) ||
        throw(DimensionMismatch("`X`, `Y`, `Z` and `H` must have same length"))

    cmapped = color ≡ nothing
    color = UnicodePlots.ansi_color(color ≡ :auto ? UnicodePlots.next_color!(plot) : color)

    mh::Float64, Mh::Float64 = UnicodePlots.is_auto(zlim) ? UnicodePlots.nanless_extrema(H) : zlim
    plot.cmap.lim = (mh, Mh)
    plot.cmap.callback = callback = UnicodePlots.colormap_callback(colormap)
    plot.cmap.bar |= cmapped

    npts = length(H)
    colors = if cmapped
        map(h -> callback(h, mh, Mh), vec(H))
    else
        fill(color, npts)
    end
    UnicodePlots.points!(plot, vec(X), vec(Y), vec(Z), colors, falses(npts))
    return plot
end

# The scale of an axis is a symbol (`:identity`, `:ln`, `:log2`, `:log10`) that the canvas turns into a function, and the function is in the type of the canvas (`BrailleCanvas{YS,XS}`): the type of a canvas, and of the plot that has it, is
# then one of sixteen when the symbol is a value that is only known when the program runs (the compiler does not carry the default of a keyword through the constructors of a plot). Only the scale that is the default is supported in a program: the
# symbol is then a function that is one type, and the canvas, the plot and what is done with them have the types that they have.
@device_override UnicodePlots.scale_callback(scale::Symbol) = scale === :identity ? identity : error("only the `:identity` scale of an axis is supported in a compiled program")

# The limits of an axis are `Float64`s, or the integers that were given (`lims` as `(0, 0)` when the plot is not given any): a value of one of two types, which is the type of the origin of the canvas, of the keywords that the canvas is
# made with, and so of a call that the compiler can only make when the program runs. They are all `Float64` here.
@device_override function UnicodePlots.extend_limits(vec::AbstractVector, lims, scale::Union{Symbol,Function})
    scale = UnicodePlots.scale_callback(scale)
    mi, ma = UnicodePlots.as_float(extrema(lims))
    if iszero(mi) && iszero(ma)
        if isempty(vec)
            auto = UnicodePlots.is_auto(lims)
            lo, hi = auto ? (-1.0, 1.0) : UnicodePlots.as_float(lims)
            return Float64(lo), Float64(hi)
        end
        mi, ma = UnicodePlots.as_float(extrema(vec))
    end
    if mi == ma
        mi -= 1
        ma += 1
    end
    if scale ≡ identity
        if UnicodePlots.is_auto(lims)
            r = UnicodePlots.plotting_range_narrow(mi, ma)
            return Float64(r[1]), Float64(r[2])
        end
        return Float64(mi), Float64(ma)
    end
    return Float64(scale(mi)), Float64(scale(ma))
end

# The color map of a plot: a function of the value, made of the scheme that has the name (`colorschemes[cmap]`, a dictionary of all the schemes, by a name that is a value when the program runs). The type of the scheme is
# then one of the types that they have in the dictionary (`ColorScheme{V,T}`), and the function that has it is a closure of an abstract type that `ColorMap` has a type parameter of. The schemes that the package has are all of one type
# (that of the default): a scheme of another type is an error.
const COLORSCHEME = typeof(UnicodePlots.ColorSchemes.colorschemes[:viridis])

@device_override function UnicodePlots.colormap_callback(cmap::Symbol)
    cdata = UnicodePlots.ColorSchemes.colorschemes[cmap]::COLORSCHEME
    return (z, minz, maxz) -> begin
        isfinite(z) || return UnicodePlots.INVALID_COLOR
        z01 =
            minz == maxz ? zero(z) :
            (max(minz, min(z, maxz)) - minz) / (maxz - minz)
        isfinite(z01) || return UnicodePlots.INVALID_COLOR
        UnicodePlots.ansi_color(get(cdata, z01))
    end::UnicodePlots.ColorType
end

end # module
