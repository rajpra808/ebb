import EbbCLI

/// The commands live in the EbbCLI library so tests can exercise them.
/// An explicit async entry point makes sure ArgumentParser's async `main`
/// is the one that runs.
@main
enum EbbMain {
    static func main() async {
        await Ebb.main()
    }
}
