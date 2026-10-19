import Foundation
import Testing
import ZCodeAppCore
import ZCodeTestSupport
import ZCodeV4
import ZCodeWire

private func realOverview() throws -> PluginsOverview {
    try PluginsOverview(json: Fixtures.record(in: "v3.15.1/plugins-read", prefix: "001"))
}

private func available(_ name: String, _ marketplace: String, category: String? = nil, author: String? = nil,
                       description: String? = nil, displayName: String? = nil,
                       descriptionFr: String? = nil) -> AvailablePlugin {
    AvailablePlugin(
        id: "\(name)@\(marketplace)", name: name, marketplace: marketplace, description: description,
        listing: PluginListing(displayName: displayName, descriptionI18n: descriptionFr.map { ["fr": $0] } ?? [:],
                               category: category, author: author))
}

private func installed(_ name: String, _ marketplace: String, displayName: String? = nil) -> InstalledPlugin {
    InstalledPlugin(id: "\(name)@\(marketplace)", name: name, marketplace: marketplace,
                    listing: displayName.map { PluginListing(displayName: $0) })
}

struct PluginCatalogLayoutTests {
    @Test func catalogueParSource() throws {
        let layout = PluginCatalogLayout.make(try realOverview(), query: "", category: nil)
        // Le catalogue réel n'a des plugins que dans la source officielle de ZCode ; la source Claude, vide, n'a pas de section.
        #expect(layout.catalog.map(\.id) == ["zcode-plugins-official"])
        let first = try #require(layout.catalog.first)
        #expect(first.isOfficial)
        #expect(first.title == "Officiel ZCode")
        #expect(first.plugins.count == 61)
        #expect(layout.installed.map(\.id) == ["github@zcode-plugins-official"])
        #expect(layout.restorable.isEmpty)
        // Triées par libellé français : Finance, Outils de développement, Productivité, Utilitaires.
        #expect(layout.categories == ["finance", "developer-tools", "productivity", "utilities"])
    }

    @Test func sourcesOrdonnees() {
        let overview = PluginsOverview(
            marketplaces: [
                MarketplaceSummary(id: "zeta", name: "zeta"),
                MarketplaceSummary(id: "claude-plugins-official", name: "claude-plugins-official", isOfficial: true),
                MarketplaceSummary(id: "alpha", name: "alpha"),
                MarketplaceSummary(id: "zcode-plugins-official", name: "zcode-plugins-official", isOfficial: true),
                MarketplaceSummary(id: "vide", name: "vide"),
            ],
            availablePlugins: [
                available("z1", "zeta"), available("c1", "claude-plugins-official"),
                available("a1", "alpha"), available("o1", "zcode-plugins-official"),
                available("inconnu", "ailleurs"),
            ])
        let layout = PluginCatalogLayout.make(overview, query: "", category: nil)
        // Officiel ZCode d'abord, puis les autres par titre : alpha, Officiel Claude, zeta.
        #expect(layout.catalog.map(\.id) == ["zcode-plugins-official", "alpha", "claude-plugins-official", "zeta"])
        #expect(layout.catalog.map(\.isOfficial) == [true, false, true, false])
        // Un plugin dont la source n'est pas connue ne figure pas au catalogue.
        #expect(!layout.catalog.flatMap(\.plugins).contains { $0.name == "inconnu" })
    }

    @Test func rechercheSansAccents() throws {
        let overview = try realOverview()
        let productivity = overview.availablePlugins.filter { $0.listing?.category == "productivity" }
        #expect(!productivity.isEmpty)
        let layout = PluginCatalogLayout.make(overview, query: "productivite", category: nil)
        let found = layout.catalog.flatMap(\.plugins)
        #expect(Set(found.map(\.id)).isSuperset(of: Set(productivity.map(\.id))))
        let github = PluginCatalogLayout.make(overview, query: "GITHUB", category: nil).catalog.flatMap(\.plugins)
        #expect(github.contains { $0.name == "github" })
        #expect(PluginCatalogLayout.make(overview, query: "zzz-introuvable", category: nil).catalog.isEmpty)
    }

    @Test func rechercheSurLesChampsAffiches() {
        let overview = PluginsOverview(
            marketplaces: [MarketplaceSummary(id: "m", name: "m")],
            availablePlugins: [
                available("alpha", "m", displayName: "Éditeur Magique"),
                available("beta", "m", author: "Zoë Durand"),
                available("gamma", "m", description: "Outil Générique", descriptionFr: "Révise le texte"),
                available("delta", "m", category: "utilities"),
            ])
        func names(_ query: String) -> [String] {
            PluginCatalogLayout.make(overview, query: query, category: nil).catalog.flatMap(\.plugins).map(\.name)
        }
        #expect(names("editeur magique") == ["alpha"])
        #expect(names("zoe") == ["beta"])
        // La description française prime sur la description brute.
        #expect(names("revise") == ["gamma"])
        #expect(names("generique").isEmpty)
        #expect(names("utilitaires") == ["delta"])
        #expect(names("  ALPHA ") == ["alpha"])
    }

    @Test func filtreDeCategorie() throws {
        let overview = try realOverview()
        let layout = PluginCatalogLayout.make(overview, query: "", category: "finance")
        let found = layout.catalog.flatMap(\.plugins)
        #expect(!found.isEmpty)
        #expect(found.allSatisfy { $0.listing?.category == "finance" })
        #expect(found.count == overview.availablePlugins.filter { $0.listing?.category == "finance" }.count)
        // Le filtre ne réduit pas les catégories proposées.
        #expect(layout.categories.count == 4)
    }

    @Test func orphelinSansSource() {
        let overview = PluginsOverview(
            marketplaces: [MarketplaceSummary(id: "m", name: "m")],
            installedPlugins: [installed("zeta", "m"), installed("perdu", "disparue", displayName: "Alpha perdu"),
                               installed("beta", "m", displayName: "Beta")])
        let layout = PluginCatalogLayout.make(overview, query: "", category: nil)
        // Triés par nom affiché, orphelins compris.
        #expect(layout.installed.map(\.name) == ["perdu", "beta", "zeta"])
        let orphan = layout.installed[0]
        #expect(PluginCatalogLayout.isOrphan(orphan, in: overview))
        #expect(!PluginCatalogLayout.isOrphan(layout.installed[1], in: overview))
        #expect(PluginCatalogLayout.sourceTitle("disparue", in: overview) == "disparue")
        #expect(PluginCatalogLayout.sourceTitle("m", in: overview) == "m")
        #expect(PluginCatalogLayout.sourceTitle("", in: overview) == nil)
    }

    @Test func aRetablirTries() {
        let overview = PluginsOverview(
            marketplaces: [MarketplaceSummary(id: "m", name: "m")],
            restorableBuiltins: [available("zz", "m"), available("aa", "m", displayName: "Premier")])
        #expect(PluginCatalogLayout.make(overview, query: "", category: nil).restorable.map(\.name) == ["aa", "zz"])
    }
}
