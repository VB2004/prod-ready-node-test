import express from "express";
import { logger } from "./logger.js";

const app = express();
const PORT = process.env.PORT || 3000;

app.use((req, res, next) => {
  logger.dev(`${req.method} ${req.url}`, {
    body: req.body,
    headers: req.headers,
  });

  next();
});

app.get("/", (_, res) => {
  res.send("Backend up ✅");
});

// Endpoint to generate random logs
app.get("/generate-logs", (_, res) => {
  const messages = [
    "User login successful",
    "Payment failed",
    "Cache refreshed",
    "Database connection slow",
    "Order placed successfully",
    "User profile updated",
    "Unknown API key detected",
    "Service restarted",
    "Metrics flushed",
  ];

  for (let i = 0; i < 10; i++) {
    const random = messages[Math.floor(Math.random() * messages.length)];
    const level = Math.floor(Math.random() * 4); // 0–3

    switch (level) {
      case 0:
        logger.error(random, { requestId: i });
        break;
      case 1:
        logger.warn(random, { requestId: i });
        break;
      case 2:
        logger.info(random, { requestId: i });
        break;
      default:
        logger.debug(random, { requestId: i });
    }
  }

  res.send("✅ Generated 10 random logs");
});

app.get("/healthz", (_, res) => {
  res.status(200).json({ status: "ok" });
});

app.listen(PORT, () => {
  logger.info(`Server running on port ${PORT}`);
});
