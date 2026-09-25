import SwiftUI

/// Makes a `List` row read as ordinary screen content instead of a list
/// row — no separator, no card background, horizontal padding matching the
/// screen's own content margin. Introduced with the round-12 `List`
/// conversion (Overdue/Upcoming, reversing R52): both screens' header
/// content (subtitle, segmented control, digest/lede text) sits above the
/// sectioned, card-styled rows and needs to look the same as it did back
/// when it was plain `ScrollView` content, not a list row of its own.
extension View {
    func plainListRow(topPadding: CGFloat = 0, bottomPadding: CGFloat = 0) -> some View {
        self
            .listRowInsets(EdgeInsets(top: topPadding, leading: 20, bottom: bottomPadding, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
