import Foundation

/**
    A closure that, when evaluated, returns a dictionary of key-value
    pairs that can be accessed from within a group of shared examples.
*/
public typealias SharedExampleContext = () -> [String: Any]

/**
    A closure that is used to define a group of shared examples. This
    closure may contain any number of example and example groups.
*/
public typealias SharedExampleClosure = (@escaping SharedExampleContext) -> Void

/**
    A collection of state Quick builds up in order to work its magic.
    World is primarily responsible for maintaining a mapping of QuickSpec
    classes to root example groups for those classes.

    It also maintains a mapping of shared example names to shared
    example closures.

    You may configure how Quick behaves by calling the -[World configure:]
    method from within an overridden +[QuickConfiguration configure:] method.
*/
final internal class World: NSObject {
    /**
        The example group that is currently being run.
        The DSL requires that this group is correctly set in order to build a
        correct hierarchy of example groups and their examples.
    */
    internal var currentExampleGroup: ExampleGroup!

    /**
        The example metadata of the test that is currently being run.
        This is useful for using the Quick test metadata (like its name) at
        runtime.
    */

    internal var currentExampleMetadata: ExampleMetadata?

    /**
        A flag that indicates whether additional test suites are being run
        within this test suite. This is only true within the context of Quick
        functional tests.
    */
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    // Convention of generating Objective-C selector has been changed on Swift 3
    @objc(isRunningAdditionalSuites)
    internal var isRunningAdditionalSuites = false
#else
    internal var isRunningAdditionalSuites = false
#endif

    private var specs: [String: ExampleGroup] = [:]
    private var sharedExamples: [String: SharedExampleClosure] = [:]
    private let configuration = Configuration()

    internal private(set) var isConfigurationFinalized = false

    internal var exampleHooks: ExampleHooks {return configuration.exampleHooks }
    internal var suiteHooks: SuiteHooks { return configuration.suiteHooks }

    // MARK: Singleton Constructor

    private override init() {}

#if (os(macOS) || os(iOS) || os(tvOS) || os(watchOS)) && !SWIFT_PACKAGE
    @objc
    static let sharedWorld = World()
#else
    static let sharedWorld = World()
#endif

    // MARK: Public Interface

    /**
        Exposes the World's Configuration object within the scope of the closure
        so that it may be configured. This method must not be called outside of
        an overridden +[QuickConfiguration configure:] method.

        - parameter closure:  A closure that takes a Configuration object that can
                         be mutated to change Quick's behavior.
    */
#if (os(macOS) || os(iOS) || os(tvOS) || os(watchOS)) && !SWIFT_PACKAGE
    @objc
    internal func configure(_ closure: QuickConfigurer) {
        _configure(closure)
    }
#else
    internal func configure(_ closure: QuickConfigurer) {
        _configure(closure)
    }
#endif
    private func _configure(_ closure: QuickConfigurer) {
        assert(!isConfigurationFinalized,
               "Quick cannot be configured outside of a +[QuickConfiguration configure:] method. You should not call -[World configure:] directly. Instead, subclass QuickConfiguration and override the +[QuickConfiguration configure:] method.")
        closure(configuration)
    }

    /**
        Finalizes the World's configuration.
        Any subsequent calls to World.configure() will raise.
    */
#if (os(macOS) || os(iOS) || os(tvOS) || os(watchOS)) && !SWIFT_PACKAGE
    @objc
    internal func finalizeConfiguration() { isConfigurationFinalized = true }
#else
    internal func finalizeConfiguration() { isConfigurationFinalized = true }
#endif

    /**
        Returns an internally constructed root example group for the given
        QuickSpec class.

        A root example group with the description "root example group" is lazily
        initialized for each QuickSpec class. This root example group wraps the
        top level of a -[QuickSpec spec] method--it's thanks to this group that
        users can define beforeEach and it closures at the top level, like so:

            override func spec() {
                // These belong to the root example group
                beforeEach {}
                it("is at the top level") {}
            }

        - parameter cls: The QuickSpec class for which to retrieve the root example group.
        - returns: The root example group for the class.
    */
#if (os(macOS) || os(iOS) || os(tvOS) || os(watchOS)) && !SWIFT_PACKAGE
    @objc
    internal func rootExampleGroupForSpecClass(_ cls: AnyClass) -> ExampleGroup {
        return _rootExampleGroupForSpecClass(cls)
    }
#else
    internal func rootExampleGroupForSpecClass(_ cls: AnyClass) -> ExampleGroup {
        return _rootExampleGroupForSpecClass(cls)
    }
#endif
    private func _rootExampleGroupForSpecClass(_ cls: AnyClass) -> ExampleGroup {
        let name = String(describing: cls)

        if let group = specs[name] {
            return group
        } else {
            let group = ExampleGroup(
                description: "root example group",
                flags: [:],
                isInternalRootExampleGroup: true
            )
            specs[name] = group
            return group
        }
    }

    /**
        Returns all examples that should be run for a given spec class.
        There are two filtering passes that occur when determining which examples should be run.
        That is, these examples are the ones that are included by inclusion filters, and are
        not excluded by exclusion filters.

        - parameter specClass: The QuickSpec subclass for which examples are to be returned.
        - returns: A list of examples to be run as test invocations.
    */
    internal func examples(_ specClass: AnyClass) -> [Example] {
        // 1. Grab all included examples.
        let included = includedExamples
        // 2. Grab the intersection of (a) examples for this spec, and (b) included examples.
        let spec = rootExampleGroupForSpecClass(specClass).examples.filter { included.contains($0) }
        // 3. Remove all excluded examples.
        return spec.filter { example in
            !self.configuration.exclusionFilters.reduce(false) { $0 || $1(example) }
        }
    }

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    @objc(examplesForSpecClass:)
    private func objc_examples(_ specClass: AnyClass) -> [Example] {
        return examples(specClass)
    }
#endif

    // MARK: Internal

    internal func registerSharedExample(_ name: String, closure: @escaping SharedExampleClosure) {
        raiseIfSharedExampleAlreadyRegistered(name)
        sharedExamples[name] = closure
    }

    internal func sharedExample(_ name: String) -> SharedExampleClosure {
        raiseIfSharedExampleNotRegistered(name)
        return sharedExamples[name]!
    }

    internal var includedExampleCount: Int {
        return includedExamples.count
    }

    internal var beforesCurrentlyExecuting: Bool {
        let suiteBeforesExecuting = suiteHooks.phase == .beforesExecuting
        let exampleBeforesExecuting = exampleHooks.phase == .beforesExecuting
        var groupBeforesExecuting = false
        if let runningExampleGroup = currentExampleMetadata?.example.group {
            groupBeforesExecuting = runningExampleGroup.phase == .beforesExecuting
        }

        return suiteBeforesExecuting || exampleBeforesExecuting || groupBeforesExecuting
    }

    internal var aftersCurrentlyExecuting: Bool {
        let suiteAftersExecuting = suiteHooks.phase == .aftersExecuting
        let exampleAftersExecuting = exampleHooks.phase == .aftersExecuting
        var groupAftersExecuting = false
        if let runningExampleGroup = currentExampleMetadata?.example.group {
            groupAftersExecuting = runningExampleGroup.phase == .aftersExecuting
        }

        return suiteAftersExecuting || exampleAftersExecuting || groupAftersExecuting
    }

#if (os(macOS) || os(iOS) || os(tvOS) || os(watchOS)) && !SWIFT_PACKAGE
    @objc
    internal func performWithCurrentExampleGroup(_ group: ExampleGroup, closure: () -> Void) {
        _performWithCurrentExampleGroup(group, closure: closure)
    }
#else
    internal func performWithCurrentExampleGroup(_ group: ExampleGroup, closure: () -> Void) {
        _performWithCurrentExampleGroup(group, closure: closure)
    }
#endif
    private func _performWithCurrentExampleGroup(_ group: ExampleGroup, closure: () -> Void) {
        let previousExampleGroup = currentExampleGroup
        currentExampleGroup = group

        closure()

        currentExampleGroup = previousExampleGroup
    }

    private var allExamples: [Example] {
        var all: [Example] = []
        for (_, group) in specs {
            group.walkDownExamples { all.append($0) }
        }
        return all
    }

    private var includedExamples: [Example] {
        let all = allExamples
        let included = all.filter { example in
            return self.configuration.inclusionFilters.reduce(false) { $0 || $1(example) }
        }

        if included.isEmpty && configuration.runAllWhenEverythingFiltered {
            return all
        } else {
            return included
        }
    }

    private func raiseIfSharedExampleAlreadyRegistered(_ name: String) {
        if sharedExamples[name] != nil {
            raiseError("A shared example named '\(name)' has already been registered.")
        }
    }

    private func raiseIfSharedExampleNotRegistered(_ name: String) {
        if sharedExamples[name] == nil {
            raiseError("No shared example named '\(name)' has been registered. Registered shared examples: '\(Array(sharedExamples.keys))'")
        }
    }
}
