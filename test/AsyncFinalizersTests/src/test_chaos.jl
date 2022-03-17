module TestChaos

using Test

function run_chaos(filename; addenv = nothing)
    path = joinpath(@__DIR__, filename)
    script = """
    $(Base.load_path_setup_code())
    include($(repr(path)))
    """
    cmd = Base.julia_cmd()
    cmd = `$cmd -e $script`
    if addenv !== nothing
        cmd = Base.addenv(cmd, addenv...)
    end
    pipe = Pipe()
    process =
        run(pipeline(cmd; stdin = devnull, stdout = pipe, stderr = pipe); wait = false)
    close(pipe.in)
    output = read(pipe, String)
    wait(process)
    if !success(process)
        @info "Tests in subprocess failed" filename addenv Text(output)
    end
    @test success(process)
    return output
end

function test_recovery_takemanyto()
    output = run_chaos(
        "exec_chaos_recovery.jl";
        addenv = ("ASYNCFINALIZERSTESTS_CHAOS" => "takemanyto",),
    )
    @test occursin("Unexpected failure in finalizer queue", output)
end

function test_recovery_run_finalizers()
    output = run_chaos(
        "exec_chaos_recovery.jl";
        addenv = ("ASYNCFINALIZERSTESTS_CHAOS" => "run_finalizers",),
    )
    @test occursin("Error from async finalizer executor", output)
end

function test_fallback()
    output = run_chaos("exec_chaos_fallback.jl")
    @test occursin("Switching to fallback", output)
end

end  # module
