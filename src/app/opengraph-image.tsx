import { ImageResponse } from "next/og";

export const alt =
  "Sweats — Trade shares of poker players live";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default function OG() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          padding: "84px 88px",
          background:
            "radial-gradient(ellipse at 80% 0%, rgba(239,43,43,0.45) 0%, transparent 55%), radial-gradient(ellipse at 10% 100%, rgba(185,28,28,0.25) 0%, transparent 60%), #0a0a0a",
          color: "#fff",
          fontFamily:
            "ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont",
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 18 }}>
          <div
            style={{
              width: 76,
              height: 76,
              borderRadius: 22,
              background: "#ef2b2b",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              fontWeight: 900,
              fontSize: 52,
              boxShadow: "0 0 40px rgba(239,43,43,0.55)",
            }}
          >
            S
          </div>
          <div
            style={{
              display: "flex",
              flexDirection: "column",
              lineHeight: 1,
            }}
          >
            <span
              style={{
                fontSize: 44,
                fontWeight: 900,
                letterSpacing: -1.5,
              }}
            >
              SWEATS
            </span>
            <span
              style={{
                fontSize: 14,
                marginTop: 6,
                textTransform: "uppercase",
                letterSpacing: 4,
                color: "rgba(255,255,255,0.55)",
              }}
            >
              Live poker markets
            </span>
          </div>
        </div>

        <div
          style={{
            display: "flex",
            flexDirection: "column",
            marginTop: "auto",
          }}
        >
          <div
            style={{
              display: "flex",
              flexWrap: "wrap",
              fontSize: 96,
              fontWeight: 900,
              letterSpacing: -3.5,
              lineHeight: 0.96,
              maxWidth: 980,
            }}
          >
            <span>Trade shares of poker players&nbsp;</span>
            <span style={{ color: "#ef2b2b" }}>live.</span>
          </div>
          <div
            style={{
              fontSize: 26,
              color: "rgba(255,255,255,0.7)",
              marginTop: 28,
              maxWidth: 880,
            }}
          >
            Buy shares of players when they sit. Trade their swings. Cash
            out when they do.
          </div>
        </div>

        <div
          style={{
            position: "absolute",
            bottom: 36,
            right: 88,
            fontSize: 18,
            color: "rgba(255,255,255,0.4)",
            letterSpacing: 1.5,
          }}
        >
          sweats.poker
        </div>
      </div>
    ),
    size,
  );
}
