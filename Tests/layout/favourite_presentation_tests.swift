import SwiftUI

@main
struct FavouritePresentationTests {
    @MainActor
    static func main() {
        let favourites = NavigationDestination.swiftUI(.favouriteServerList)
        let navigation = NavigationManager()

        // Opening on the outer display pushes one page, even on repeated taps.
        navigation.openFavouriteServers()
        navigation.openFavouriteServers()
        precondition(navigation.navigationPath == [favourites])

        // Unfolding moves the already-open page out of the sidebar into a sheet.
        navigation.updateFavouriteServersLayout(usesTabletLayout: true)
        precondition(navigation.navigationPath.isEmpty)
        precondition(navigation.presentsFavouriteServersSheet)

        // Folding waits for the sheet to finish dismissing before pushing.
        navigation.updateFavouriteServersLayout(usesTabletLayout: false)
        precondition(!navigation.presentsFavouriteServersSheet)
        precondition(navigation.navigationPath.isEmpty)
        navigation.favouriteServersSheetDidDismiss()
        precondition(navigation.navigationPath == [favourites])

        // Going back closes the page; unfolding must not bring it back.
        navigation.goBack()
        navigation.updateFavouriteServersLayout(usesTabletLayout: true)
        precondition(!navigation.presentsFavouriteServersSheet)

        // A rapid close/open during sheet dismissal resolves to the latest pose.
        navigation.openFavouriteServers()
        navigation.updateFavouriteServersLayout(usesTabletLayout: false)
        navigation.updateFavouriteServersLayout(usesTabletLayout: true)
        navigation.favouriteServersSheetDidDismiss()
        precondition(navigation.presentsFavouriteServersSheet)
        precondition(navigation.navigationPath.isEmpty)

        // User dismissal is final and must not be mistaken for a layout migration.
        navigation.presentsFavouriteServersSheet = false
        navigation.favouriteServersSheetDidDismiss()
        navigation.updateFavouriteServersLayout(usesTabletLayout: false)
        precondition(navigation.navigationPath.isEmpty)

        // Preserve an open editor in both directions until its onDismiss fires.
        navigation.openFavouriteServers()
        navigation.setFavouriteEditorPresented(true)
        navigation.updateFavouriteServersLayout(usesTabletLayout: true)
        precondition(navigation.navigationPath == [favourites])
        precondition(!navigation.presentsFavouriteServersSheet)
        navigation.setFavouriteEditorPresented(false)
        precondition(navigation.navigationPath.isEmpty)
        precondition(navigation.presentsFavouriteServersSheet)
        navigation.setFavouriteEditorPresented(true)
        navigation.updateFavouriteServersLayout(usesTabletLayout: false)
        precondition(navigation.presentsFavouriteServersSheet)
        navigation.setFavouriteEditorPresented(false)
        precondition(!navigation.presentsFavouriteServersSheet)
        navigation.favouriteServersSheetDidDismiss()
        precondition(navigation.navigationPath == [favourites])

        // A different destination must never be popped by a size-class change.
        navigation.navigate(to: .swiftUI(.favouriteServerEdit(primaryKey: 7)))
        let editorPath = navigation.navigationPath
        navigation.updateFavouriteServersLayout(usesTabletLayout: true)
        precondition(navigation.navigationPath == editorPath)
        precondition(!navigation.presentsFavouriteServersSheet)

        print("Favourite presentation: all regression checks passed")
    }
}
