import SwiftUI

public struct TransparencyScreen: View {
    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                claimCard
                    .padding(.horizontal, 16)
                    .padding(.top, 14)

                proofsSection
                auditSection

                Text("Data Not Collected is our App Store declaration too. Lying there is grounds for removal.")
                    .font(.caption)
                    .foregroundStyle(RegardsDS.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .frame(maxWidth: .infinity)

                Color.clear.frame(height: 40)
            }
        }
        .background(RegardsDS.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("screen.transparency")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Transparency")
                .font(.system(.largeTitle, weight: .bold))
                .foregroundStyle(RegardsDS.ink)
                .accessibilityAddTraits(.isHeader)
            Text("We say no call-home. Here's how you can check.")
                .font(RegardsFont.serifItalic(.title3))
                .foregroundStyle(RegardsDS.muted)
                .lineSpacing(2)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    // Hoisted out of the view body — the long `+` concatenation inline in
    // a `Text(...)` was tipping Swift's type-checker into "unable to type-
    // check this expression in reasonable time" on the claimCard view.
    private static let claimBody: String = """
        Any iOS app can open a socket — there's no permission to \
        withhold — so the guarantee is source-auditable instead. The \
        app's source has zero call sites to URLSession, NWConnection, \
        CFReadStream, URLRequest, or similar networking primitives. \
        CI greps every PR and fails the build the moment one appears. \
        App Transport Security is a second fence underneath, set to \
        deny all loads. Pull the source, grep it, rebuild the binary \
        yourself.
        """

    private var claimCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No call-home. Source-auditable, end to end.")
                .font(.system(.title, design: .serif).italic())
                .foregroundStyle(.white)
                .lineSpacing(3)
            Text(Self.claimBody)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.92))
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        // `accentInk` (darker) instead of `accent` so white body copy passes
        // AA body contrast — white-on-accent measures ~3.7:1 (fails body AA);
        // white-on-accentInk measures ~8:1.
        .background(RegardsDS.accentInk, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var proofsSection: some View {
        VStack(spacing: 0) {
            SectionHeader("Technical proofs")
            RegardsCard {
                VStack(spacing: 0) {
                    proofRow(
                        label: "Zero networking call sites (source-auditable)",
                        status: "Foundation itself is of course linked — that's not the claim. "
                              + "The claim is that the app's source code contains no calls to "
                              + "URLSession, NWConnection, CFReadStream, or any other networking "
                              + "primitive. CI greps every PR and fails the build if a match "
                              + "appears; App Transport Security is a second fence underneath.",
                        value: "git grep \"URLSession|NWConnection|CFReadStream|URLRequest\"  # → 0 hits"
                    )
                    Hair(inset: 16)
                    proofRow(
                        label: "No third-party SDKs (only GRDB linked)",
                        status: "GRDB is the SQLite wrapper; it never opens a socket. "
                              + "No analytics SDK, no telemetry, no ad library, no crash reporter. "
                              + "Privacy Manifest declares 'Data Not Collected' across the board.",
                        value: nil
                    )
                    Hair(inset: 16)
                    proofRow(
                        label: "Encrypted at rest",
                        status: "iOS Data Protection on the database file. Encrypted while the device is locked.",
                        value: nil
                    )
                }
            }
        }
    }

    private var auditSection: some View {
        VStack(spacing: 0) {
            SectionHeader("Audit yourself")
            RegardsCard {
                VStack(spacing: 0) {
                    auditRow("Read the source",
                             detail: "github.com/consideratesoftware/RegardsMobileApp",
                             isAccent: true)
                    Hair(inset: 16)
                    auditRow("Rebuild the binary",
                             detail: "reproducible-builds.md · compare SHA-256")
                    Hair(inset: 16)
                    auditRow("Watch the network",
                             detail: "Little Snitch / Proxyman walkthrough")
                }
            }
        }
    }

    private func proofRow(label: String, status: String, value: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(RegardsDS.accent).frame(width: 20, height: 20)
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            }
            .padding(.top, 2)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RegardsDS.ink)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(RegardsDS.muted)
                    .lineSpacing(2)
                if let value {
                    Text(value)
                        .font(RegardsFont.mono(.caption))
                        .foregroundStyle(RegardsDS.muted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RegardsDS.hairSoft, in: RoundedRectangle(cornerRadius: 6))
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func auditRow(_ title: String, detail: String, isAccent: Bool = false) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(RegardsDS.ink)
                Text(detail)
                    .font(RegardsFont.mono(.caption))
                    .foregroundStyle(isAccent ? RegardsDS.accentInk : RegardsDS.muted)
            }
            Spacer()
            // Stub — Phase 1 wires these to Safari deep links. Muted until
            // interactive so it doesn't look tap-affordable.
            Text("Open")
                .font(.subheadline)
                .foregroundStyle(RegardsDS.muted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}
