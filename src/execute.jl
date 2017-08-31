###################
# CodeInfo Lookup #
###################

get_world_age() = ccall(:jl_get_tls_world_age, UInt, ()) # ccall(:jl_get_world_counter, UInt, ())

function lookup_code_info(::Type{S}, arg_names::Vector,
                          debug::Bool = false,
                          world::UInt = typemax(UInt)) where {S<:Tuple}
    if debug
        println("-----------------------------------")
        println("LOOKING UP CODEINFO FOR:")
        println("\tSIGNATURE: ", S)
        println("\tWORLD: ", world)
    end
    method, code_info = _lookup_code_info(S, arg_names, world)
    debug && println("LOOKED UP METHOD: ", method)
    debug && println("LOOKED UP CODEINFO: ", code_info)
    return code_info
end

function _lookup_code_info(::Type{S}, arg_names::Vector,
                           world::UInt = typemax(UInt)) where {S<:Tuple}
    # retrieve initial Method + CodeInfo
    methods = Base._methods_by_ftype(S, -1, world)
    length(methods) == 1 || return nothing
    type_signature, raw_static_params, method = first(methods)
    method_instance = Core.Inference.code_for_method(method, type_signature, raw_static_params, world, false)
    method_signature = method.sig
    static_params = Any[raw_static_params...]
    code_info = Core.Inference.retrieve_code_info(method_instance)
    isa(code_info, CodeInfo) || return nothing

    # substitute static parameters/varargs
    body = Expr(:block)
    body.args = code_info.code
    if method.isva
        nargs = method.nargs
        new_nargs = length(arg_names) + 1
        new_slotnames = code_info.slotnames[1:(nargs - 1)]
        new_slotflags = code_info.slotflags[1:(nargs - 1)]
        for i in nargs:new_nargs
            push!(new_slotnames, arg_names[i - 1])
            push!(new_slotflags, 0x00)
        end
        append!(new_slotnames, code_info.slotnames[(nargs + 1):end])
        append!(new_slotflags, code_info.slotflags[(nargs + 1):end])
        offset = new_nargs - nargs
        vararg_tuple = Expr(:call, GlobalRef(Core, :tuple), [SlotNumber(i) for i in nargs:new_nargs]...)
        new_slots = Any[SlotNumber(i) for i in 1:(method.nargs - 1)]
        push!(new_slots, vararg_tuple)
        Base.Core.Inference.substitute!(body, new_nargs, new_slots, method_signature, static_params, offset)
        code_info.slotnames = new_slotnames
        code_info.slotflags = new_slotflags
    else
        Base.Core.Inference.substitute!(body, 0, Any[], method_signature, static_params, 0)
    end

    return method, code_info
end

##################################
# Subexpression/CodeInfo Munging #
##################################

# Match Replacement

replace_match!(f, ismatch, x) = x

replace_match!(f, ismatch, code_info::CodeInfo) = (replace_match!(f, ismatch, code_info.code); code_info)

function replace_match!(f, ismatch, lines::AbstractArray)
    for i in eachindex(lines)
        line = lines[i]
        if ismatch(line)
            lines[i] = f(line)
        elseif isa(line, Expr)
            replace_match!(f, ismatch, line.args)
        end
    end
    return lines
end

# Call Replacement

function is_replaceable_call(x)
    if isa(x, Expr) && (x.head == :call)
        if isa(x.args[1], GlobalRef)
            return x.args[1].mod != Core
        else
            return true
        end
    end
    return false
end

function transform_call!(f, call::Expr)
    call.args[1] = f(replace_calls!(f, Any[call.args[1]])[])
    for i in 2:length(call.args)
        call.args[i] = replace_calls!(f, Any[call.args[i]])[]
    end
    return call
end

replace_calls!(f, x) = replace_match!(call -> transform_call!(f, call), is_replaceable_call, x)

# SlotNumber Replacement

replace_slotnumbers!(f, x) = replace_match!(f, s -> isa(s, SlotNumber), x)

#########
# Enter #
#########

struct Enter{C<:Context,F,d,w}
    context::C
    func::F
    debug::Val{d}
    world::Val{w}
    @inline function Enter(context::C,
                           func::F,
                           debug::Val{d} = Val(false),
                           world::Val{w} = Val(get_world_age())) where {C<:Context,F,d,w}
        return new{C,F,d,w}(context, func, debug, world)
    end
end

unwrap(e::Enter) = e.func

function intercept_calls!(code_info, f_name::Symbol, arg_names::Vector, debug::Bool = false)
    if isa(code_info, CodeInfo)
        replace_calls!(code_info) do call
            if !(isa(call, SlotNumber) && call.id == 1)
                return :($(Cassette.Intercept)($(SlotNumber(0)), $call))
            else
                return call
            end
        end
        replace_slotnumbers!(code_info) do sn
            if sn.id == 1
                return :($(Cassette.unwrap)($sn))
            elseif sn.id == 0
                return SlotNumber(1)
            else
                return sn
            end
        end
        debug && println("RETURNING Enter(...) BODY: ", code_info)
        code_info.inlineable = true
        return code_info
    else
        expr = quote
            $(Expr(:meta, :inline))
            $(Cassette.Intercept)($f_name)($(arg_names...))
        end
        debug && println("RETURNING Enter(...) BODY: ", expr)
        return expr
    end
end

for N in 0:MAX_ARGS
    arg_names = [Symbol("_CASSETTE_$i") for i in 2:(N+1)]
    @eval begin
        @generated function (e::Enter{C,F,d,w})($(arg_names...)) where {C<:Context,F,d,w}
            arg_types = map(T -> value(C, T), ($(arg_names...),))
            code_info = lookup_code_info(Tuple{value(C, F),arg_types...}, $arg_names, d, w)
            body = intercept_calls!(code_info, :e, $arg_names, d)
            return body
        end
    end
end

#############
# Intercept #
#############

struct Intercept{C<:Context,F,p,d,w}
    context::C
    func::F
    primitive::Val{p}
    debug::Val{d}
    world::Val{w}
    @inline function Intercept(context::C,
                               func::F,
                               primitive::Val{p} = Val(false),
                               debug::Val{d} = Val(false),
                               world::Val{w} = Val(get_world_age())) where {C<:Context,F,d,p,w}
        return new{C,F,p,d,w}(context, func, primitive, debug, world)
    end
end

@inline Intercept(e::Enter, f) = Intercept(e.context, f, Val(false), e.debug, e.world)

@inline Intercept(e::Enter) = Intercept(e.context, e.func, Val(true), e.debug, e.world)

@inline hook(i::Intercept, args...) = hook(i.world, i.context, i.func, args...)

@inline isprimitive(i::Intercept{<:Context,<:Any,true}, args...) = Val(true)
@inline isprimitive(i::Intercept{<:Context,<:Any,false}, args...) = isprimitive(i.world, i.context, i.func, args...)

@inline execute(i::Intercept, args...) = execute(isprimitive(i, args...), i, args...)
@inline execute(::Val{true}, i::Intercept, args...) = execution(i.world, i.context, i.func, args...)
@inline execute(::Val{false}, i::Intercept, args...) = Enter(i.context, i.func, i.debug, i.world)(args...)

@inline (i::Intercept)(args...) = (hook(i, args...); execute(i, args...))

############
# @execute #
############

macro execute(ctx, call)
    @assert isa(call, Expr) && call.head == :call
    f = call.args[1]
    call.args[1] = :($Cassette.Intercept($ctx($f), $f))
    return esc(call)
end