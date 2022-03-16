macro _const(ex)
    ex = esc(ex)
    if VERSION < v"1.8.0-DEV.1148"
        return ex
    else
        return Expr(:const, ex)
    end
end

const var"@const" = var"@_const"

const Historic = if USE_HISTORIC
    Base.require(Base.PkgId(Base.UUID(0xe6ec0b50ef98488aa141280ae2eaf113), "Historic"))
else
    nothing
end

@static if Historic === nothing
    macro record(_...)
        nothing
    end
else
    Historic.@define Debug
    using .Debug: @record
end
