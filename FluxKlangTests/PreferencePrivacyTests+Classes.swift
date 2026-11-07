//
//  PreferencePrivacyTests+Classes.swift
//  FluxKlangTests
//
//  The storage-class vocabulary and the default-deny policy (#124 PR1): the closed list of classes and
//  locations, the exact table of permitted locations, and the three classes key-value storage may hold.
//

import Testing
#if canImport(FluxKlangMac)
@testable import FluxKlangMac
#else
@testable import FluxKlang
#endif

extension PreferencePrivacyTests {
    /// The ruling table, written independently of the production switch.
    static let expectedLocations: [(StorageClass, [StorageLocation])] = [
        (.preference, [.localFile]),
        (.homeWiring, [.keyValue, .localFile]),
        (.environment, [.keyValue, .localFile]),
        (.catalog, [.keyValue, .localFile]),
        (.draft, [.localFile]),
        (.history, [.localFile, .privateCloudDatabase]),
        (.pluginState, [.localFile]),
        (.media, [.localFile]),
        (.trust, [.keychainThisDeviceOnly]),
        (.credential, [.keychainThisDeviceOnly]),
        (.hostLocalRoute, [.localFile]),
        (.cache, [.localFile])
    ]

    @Test func theTwelveClassesAreInDeclarationOrderWithStableRawValues() {
        let names = [
            "preference", "homeWiring", "environment", "catalog", "draft", "history",
            "pluginState", "media", "trust", "credential", "hostLocalRoute", "cache"
        ]
        #expect(StorageClass.allCases.map(\.rawValue) == names)
        for name in names { #expect(StorageClass(rawValue: name)?.rawValue == name) }
    }

    @Test func theFourLocationsAreInDeclarationOrderWithStableRawValues() {
        let names = ["keyValue", "localFile", "privateCloudDatabase", "keychainThisDeviceOnly"]
        #expect(StorageLocation.allCases.map(\.rawValue) == names)
    }

    @Test func everyClassPermitsExactlyTheLocationsOfTheTable() {
        #expect(Self.expectedLocations.map(\.0) == StorageClass.allCases)
        for (storageClass, locations) in Self.expectedLocations {
            #expect(StoragePolicy.permittedLocations(for: storageClass) == locations, "\(storageClass)")
        }
    }

    @Test func permitsAnswersEveryClassAndLocationPair() {
        var pairs = 0
        for (storageClass, locations) in Self.expectedLocations {
            for location in StorageLocation.allCases {
                #expect(StoragePolicy.permits(storageClass, location) == locations.contains(location))
                pairs += 1
            }
        }
        #expect(pairs == 48)
    }

    @Test func keyValueIsPermittedForExactlyHomeWiringEnvironmentAndCatalog() {
        let eligible = StorageClass.allCases.filter { StoragePolicy.isKeyValueEligible($0) }
        #expect(eligible == [.homeWiring, .environment, .catalog])
        for storageClass in Self.ineligibleClasses {
            #expect(!StoragePolicy.isKeyValueEligible(storageClass), "\(storageClass)")
            #expect(!StoragePolicy.permittedLocations(for: storageClass).contains(.keyValue))
        }
    }

    @Test func preferencesStayOutOfKeyValueStorage() {
        #expect(!StoragePolicy.isKeyValueEligible(.preference))
        #expect(StoragePolicy.permittedLocations(for: .preference) == [.localFile])
    }

    @Test func trustAndCredentialsAreThisDeviceOnly() {
        for storageClass in [StorageClass.trust, .credential] {
            #expect(StoragePolicy.permittedLocations(for: storageClass) == [.keychainThisDeviceOnly])
            #expect(!StoragePolicy.permits(storageClass, .localFile))
            #expect(!StoragePolicy.permits(storageClass, .keyValue))
            #expect(!StoragePolicy.permits(storageClass, .privateCloudDatabase))
        }
    }

    @Test func onlyHistoryMayUseThePrivateCloudDatabase() {
        let cloud = StorageClass.allCases.filter { StoragePolicy.permits($0, .privateCloudDatabase) }
        #expect(cloud == [.history])
        #expect(!StoragePolicy.permits(.history, .keyValue))
    }

    @Test func pluginStateAndMediaAreLocalFilesOnly() {
        #expect(StoragePolicy.permittedLocations(for: .pluginState) == [.localFile])
        #expect(StoragePolicy.permittedLocations(for: .media) == [.localFile])
    }

    @Test func anUnknownClassNameHasNoPermittedLocation() {
        for name in ["", "Preference", "plugin", "pluginstate", "media ", "unknown", "keyValue"] {
            #expect(StoragePolicy.permittedLocations(forClassNamed: name).isEmpty, "\(name)")
        }
        #expect(StoragePolicy.permittedLocations(forClassNamed: "media") == [.localFile])
        #expect(StoragePolicy.permittedLocations(forClassNamed: "catalog") == [.keyValue, .localFile])
    }

    @Test func requireEligibleAcceptsThreeClassesAndRefusesTheOtherNine() {
        for storageClass in Self.eligibleClasses {
            #expect(Self.refusal { try KeyValueAdmission.requireEligible(storageClass) } == nil)
        }
        for storageClass in Self.ineligibleClasses {
            #expect(
                Self.refusal { try KeyValueAdmission.requireEligible(storageClass) }
                    == .classNotKeyValueEligible(storageClass))
        }
        #expect(Self.eligibleClasses.count + Self.ineligibleClasses.count == StorageClass.allCases.count)
    }
}
