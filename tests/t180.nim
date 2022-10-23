# https://github.com/mratsim/weave/issues/180
import ../weave

proc run(): int =
    return 3

proc main() =
    init(Weave)
    let w = spawn run()
    let r = sync(w)
    echo r
    exit(Weave)

main()