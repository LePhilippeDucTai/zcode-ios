import Foundation
import ZCodeV4

/// Présentation pure de l'aperçu des plugins : installés, intégrés à rétablir et catalogue groupé par source. Rien n'est
/// inventé : les catégories, les sources et les descriptions viennent de la réponse de l'hôte.
public struct PluginCatalogLayout: Equatable, Sendable {
    /// Plugins d'une source connue (une section du catalogue).
    public struct Section: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let isOfficial: Bool
        public let plugins: [AvailablePlugin]

        public init(id: String, title: String, isOfficial: Bool, plugins: [AvailablePlugin]) {
            self.id = id
            self.title = title
            self.isOfficial = isOfficial
            self.plugins = plugins
        }
    }

    /// Installés, triés par nom affiché, orphelins (source retirée) compris.
    public let installed: [InstalledPlugin]
    /// Intégrés masqués, que l'on peut rétablir.
    public let restorable: [AvailablePlugin]
    /// Une section par source connue qui a des plugins ; la source officielle de ZCode d'abord, puis les autres par titre.
    public let catalog: [Section]
    /// Catégories distinctes du catalogue entier (ni la recherche ni le filtre ne les réduisent), triées par libellé.
    public let categories: [String]

    public init(installed: [InstalledPlugin] = [], restorable: [AvailablePlugin] = [], catalog: [Section] = [],
                categories: [String] = []) {
        self.installed = installed
        self.restorable = restorable
        self.catalog = catalog
        self.categories = categories
    }

    static let firstSourceId = "zcode-plugins-official"

    /// `query` : sans casse ni accents, sur le nom, le nom affiché, la description (française de préférence), l'auteur et
    /// la catégorie (valeur brute ou libellé) ; `category` : valeur brute de `listing.category`, `nil` pour toutes.
    public static func make(_ overview: PluginsOverview, query: String, category: String?) -> PluginCatalogLayout {
        let needle = SessionListLayout.normalized(query)
        func matches(_ plugin: AvailablePlugin) -> Bool {
            if let category, plugin.listing?.category != category { return false }
            guard !needle.isEmpty else { return true }
            let fields: [String?] = [
                plugin.name, displayName(plugin.name, plugin.listing),
                ExtensionsLabels.pluginDescription(plugin.description, listing: plugin.listing),
                plugin.listing?.author, plugin.listing?.category, plugin.listing?.category.map(ExtensionsLabels.category),
            ]
            return fields.contains { $0.map { SessionListLayout.normalized($0).contains(needle) } ?? false }
        }

        let installed = overview.installedPlugins.sorted { byName(displayName($0.name, $0.listing), displayName($1.name, $1.listing)) }
        let restorable = overview.restorableBuiltins.sorted { byName(displayName($0.name, $0.listing), displayName($1.name, $1.listing)) }

        var sections: [Section] = []
        var known: [AvailablePlugin] = []
        for marketplace in overview.marketplaces {
            let own = overview.availablePlugins.filter { owns(marketplace, $0.marketplace) }
            known += own
            let kept = own.filter(matches).sorted { byName(displayName($0.name, $0.listing), displayName($1.name, $1.listing)) }
            guard !kept.isEmpty else { continue }
            sections.append(Section(id: marketplace.id, title: ExtensionsLabels.marketplaceTitle(marketplace),
                                    isOfficial: marketplace.isOfficial, plugins: kept))
        }
        sections.sort { lhs, rhs in
            if lhs.id == firstSourceId || rhs.id == firstSourceId { return lhs.id == firstSourceId && rhs.id != firstSourceId }
            return byName(lhs.title, rhs.title)
        }

        let categories = Set(known.compactMap { $0.listing?.category }.filter { !$0.isEmpty })
            .sorted { byName(ExtensionsLabels.category($0), ExtensionsLabels.category($1)) }
        return PluginCatalogLayout(installed: installed, restorable: restorable, catalog: sections, categories: categories)
    }

    /// La source d'un plugin installé n'est plus dans les sources de l'hôte (retirée alors que le plugin reste installé).
    public static func isOrphan(_ plugin: InstalledPlugin, in overview: PluginsOverview) -> Bool {
        marketplace(named: plugin.marketplace, in: overview) == nil
    }

    /// Source d'un plugin d'après le nom porté par le plugin (`nom@source`) ; `nil` si elle n'est plus connue.
    public static func marketplace(named name: String, in overview: PluginsOverview) -> MarketplaceSummary? {
        overview.marketplaces.first { owns($0, name) }
    }

    /// Titre à afficher pour la source d'un plugin : celui de la source connue, sinon son nom brut ; `nil` si le nom est
    /// vide (jamais une chaîne vide à l'écran).
    public static func sourceTitle(_ name: String, in overview: PluginsOverview) -> String? {
        if let known = marketplace(named: name, in: overview) { return ExtensionsLabels.marketplaceTitle(known) }
        return name.isEmpty ? nil : name
    }

    private static func owns(_ marketplace: MarketplaceSummary, _ name: String) -> Bool {
        !name.isEmpty && (marketplace.id == name || marketplace.name == name)
    }

    private static func displayName(_ name: String, _ listing: PluginListing?) -> String {
        ExtensionsLabels.pluginDisplayName(name, listing: listing)
    }

    private static func byName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
