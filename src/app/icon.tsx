import { ImageResponse } from "next/og";

export const size = { width: 64, height: 64 };
export const contentType = "image/png";

export default function Icon() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          background: "#ef2b2b",
          color: "#fff",
          fontSize: 44,
          fontWeight: 900,
          letterSpacing: -2,
          borderRadius: 14,
          fontFamily:
            "ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont",
        }}
      >
        S
      </div>
    ),
    size,
  );
}
