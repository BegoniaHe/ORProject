using CSV
using DataFrames
using Dates
using Gurobi
using JLD2
using JuMP
using Makie, GLMakie, CairoMakie
using SDDP
using Statistics

function modify_dates(df::DataFrame)
    @assert issorted(df[!, "Start date"])

    df.Year .= year.(df[!, "Start date"])
    df.Month .= month.(df[!, "Start date"])
    df.Day .= day.(df[!, "Start date"])
    filter!([:Month, :Day] => (m, d) -> !(m == 2 && d == 29), df)

    df = combine(groupby(df, :Year)) do g
        @assert nrow(g) == 8760
        g.hour_of_year = 1:8760
        return g
    end
end

function read_generation_data(area::String)
    df = CSV.read(
        joinpath(
            @__DIR__,
            "Data",
            "Actual_generation_202001010000_202601010000_Hour_$(area).csv",
        ),
        DataFrame;
        delim = ";",
        groupmark = ',',
        decimal = '.',
        dateformat = dateformat"u d, yyyy HH:MM p",
        types = Dict(
            "Start date" => DateTime,
            "End date" => DateTime,
        ),
        missingstring = "-",
        select = [
            "Start date",
            "Wind offshore [MWh] Calculated resolutions",
            "Wind onshore [MWh] Calculated resolutions",
            "Photovoltaics [MWh] Calculated resolutions",
        ],
    )
    rename!(n -> Symbol(replace(String(n), r"\s+Calculated resolutions$" => "")), df)
    if "Wind offshore [MWh]" ∉ names(df)
        df[!, "Wind offshore [MWh]"] .= 0.0
    end
    df[!, :Area] .= area

    foreach(c -> replace!(c, missing => 0), eachcol(df))
    disallowmissing!(df)

    modify_dates(df)

    @assert issorted(df[!, "Start date"])

    return df
end

function read_generation_data(areas::Vector{String})
    dfs = vcat((read_generation_data(area) for area in areas)...)
    return dfs
end

function read_demand_data(area::String)
    df = CSV.read(
        joinpath(
            @__DIR__,
            "Data",
            "Actual_consumption_202001010000_202601010000_Hour_$(area).csv",
        ),
        DataFrame;
        delim = ";",
        groupmark = ',',
        decimal = '.',
        dateformat = dateformat"u d, yyyy HH:MM p",
        types = Dict(
            "Start date" => DateTime,
            "End date" => DateTime,        ),
        select = ["Start date", "grid load [MWh] Calculated resolutions"],
    )
    rename!(n -> Symbol(replace(String(n), r"\s+Calculated resolutions$" => "")), df)
    df[!, :Area] .= area
    foreach(c -> replace!(c, missing => 0), eachcol(df))
    disallowmissing!(df)
    modify_dates(df)
    return df
end

function read_demand_data(areas::Vector{String})
    dfs = vcat((read_demand_data(area) for area in areas)...)
    return dfs
end

function read_price_data()
    df = CSV.read(
        joinpath(@__DIR__, "Data", "Day-ahead_prices_202001010000_202601010000_Hour.csv"),
        DataFrame;
        delim = ";",
        groupmark = ',',
        decimal = '.',
        dateformat = dateformat"u d, yyyy HH:MM p",
        types = Dict(
            "Start date" => DateTime,
            "End date" => DateTime,
            "Germany/Luxembourg [€/MWh] Calculated resolutions" => Float64,
        ),
        select = ["Start date", "Germany/Luxembourg [€/MWh] Calculated resolutions"],
    )
    rename!(n -> Symbol(replace(String(n), r"\s+Calculated resolutions$" => "")), df)
    foreach(c -> replace!(c, missing => 0), eachcol(df))
    disallowmissing!(df)

    modify_dates(df)
    return df
end

function read_capacity_data(area::String)
    df = CSV.read(
        joinpath(
            @__DIR__,
            "Data",
            "Installed_generation_capacity_202001010000_202601010000_Year_$(area).csv",
        ),
        DataFrame;
        delim = ";",
        groupmark = ',',
        decimal = '.',
        dateformat = dateformat"u d, yyyy HH:MM p",
        types = Dict(
            "Start date" => DateTime,
            "End date" => DateTime,
            # "Wind offshore [MW] Original resolutions" => Float64,
            # "Wind onshore [MW] Original resolutions" => Float64,
            # "Photovoltaics [MW] Original resolutions" => Float64,
        ),
        select = [
            "Start date",
            "Wind offshore [MW] Original resolutions",
            "Wind onshore [MW] Original resolutions",
            "Photovoltaics [MW] Original resolutions",
        ],
    )

    rename!(n -> Symbol(replace(String(n), r"\s+Original resolutions$" => "")), df)
    if "Wind offshore [MW]" ∉ names(df)
        df[!, "Wind offshore [MW]"] .= 0.0
    end
    foreach(c -> replace!(c, missing => 0), eachcol(df))
    disallowmissing!(df)
    df[!, :Area] .= area
    df.Year .= year.(df[!, "Start date"])

    return df
end

function read_capacity_data(areas::Vector{String})
    dfs = vcat((read_capacity_data(area) for area in areas)...)
    return dfs
end

function calculate_availabilities(df)
    for source in ["Wind offshore", "Wind onshore", "Photovoltaics"]
        df[!, "$(source) availability"] =
            df[!, "$(source) [MWh]"] ./ df[!, "$(source) [MW]"]
        replace!(df[!, "$(source) availability"], NaN => 0.0)
    end
end

function generate_inverse_demand_parameters(data; price_elasticity = -0.2)
    data.a =
        replace(v -> v <= 0 ? 1 : v, data[!, "Germany/Luxembourg [€/MWh]"]) .*
        (1-1/price_elasticity)
    data.b =
        replace(v -> v <= 0 ? 1 : v, data[!, "Germany/Luxembourg [€/MWh]"]) ./
        (price_elasticity .* data[!, "grid load [MWh]"])
    return nothing
end

function combine_data()
    generation_data = read_generation_data(["50Hertz", "Amprion", "TenneT", "TransnetBW"])
    demand_data = read_demand_data(["50Hertz", "Amprion", "TenneT", "TransnetBW"])
    price_data = read_price_data()
    capacity_data = read_capacity_data(["50Hertz", "Amprion", "TenneT", "TransnetBW"])
    data = leftjoin(
        generation_data,
        demand_data,
        on = ["Start date", :Month, :Day, :Area, :Year, :hour_of_year],
    )
    leftjoin!(data, price_data, on = ["Start date", :Month, :Day, :Year, :hour_of_year])
    leftjoin!(data, capacity_data[!, Not(["Start date"])], on = [:Area, :Year])
    select!(
        data,
        [
            "Start date",
            "Year",
            "Month",
            "Day",
            "hour_of_year",
            "Area",
            "grid load [MWh]",
            "Wind offshore [MWh]",
            "Wind onshore [MWh]",
            "Photovoltaics [MWh]",
            "Germany/Luxembourg [€/MWh]",
            "Wind offshore [MW]",
            "Wind onshore [MW]",
            "Photovoltaics [MW]",
        ],
    )
    calculate_availabilities(data)
    generate_inverse_demand_parameters(data)
    @save joinpath(@__DIR__, "results", "data.jld2") data
    return nothing
end

function create_data_inspection(;
    plotcols = [
        "Wind offshore availability",
        "Wind onshore availability",
        "Photovoltaics availability",
    ],
    areas = ["50Hertz", "Amprion", "TenneT", "TransnetBW"],
    plotgrouping = [:Year, :Month, :Area],
)

    @load joinpath(@__DIR__, "results", "data.jld2") data
    years = sort!(unique(data[!, :Year]))
    months = sort!(unique(data[!, :Month]))

    group_map = Dict{Tuple{Int,Int,String},DataFrame}()
    for (k, g) in pairs(groupby(data, plotgrouping))
        @assert issorted(g[!, "Start date"])
        group_map[k...] = g
    end

    fig = Figure(size = (1100, 700))
    axs = [Axis(fig[i+1, 1:3], title = v) for (i, v) in enumerate(plotcols)]

    dd_year = Menu(fig[1, 1], options = years)
    dd_month = Menu(fig[1, 2], options = months)
    dd_area = Menu(fig[1, 3], options = areas)

    subdf = @lift begin
        y = years[$(dd_year.i_selected)]
        m = months[$(dd_month.i_selected)]
        a = areas[$(dd_area.i_selected)]
        group_map[(y, m, a)]
    end

    x = @lift($subdf[!, "hour_of_year"])
    ys = [@lift($subdf[!, v]) for v in plotcols]

    ls = [lines!(axs[i], x, ys[i]) for i in eachindex(plotcols)]

    on(subdf) do _
        for ax in axs
            autolimits!(ax)
            ylims!(ax, 0, 1)
        end
    end

    display(fig)

end