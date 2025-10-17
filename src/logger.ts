export enum LogLevel {
  ERROR = 0,
  WARN = 1,
  INFO = 2,
  DEBUG = 3,
}

class Logger {
  private logLevel: LogLevel;

  constructor() {
    const nodeEnv = process.env.NODE_ENV || "SANDBOX";
    this.logLevel = nodeEnv === "PRODUCTION" ? LogLevel.ERROR : LogLevel.DEBUG;
  }

  private shouldLog(level: LogLevel): boolean {
    return level <= this.logLevel;
  }

  private formatMessage(level: string, message: string, meta?: any): string {
    const timestamp = new Date().toISOString();
    const metaStr = meta ? ` | ${JSON.stringify(meta)}` : "";
    return `[${timestamp}] [${level}] ${message}${metaStr}`;
  }

  error(message: string, meta?: any): void {
    if (this.shouldLog(LogLevel.ERROR)) {
      const msg = this.formatMessage("ERROR", message, meta);
      console.error(msg);
    }
  }

  warn(message: string, meta?: any): void {
    if (this.shouldLog(LogLevel.WARN)) {
      const msg = this.formatMessage("WARN", message, meta);
      console.warn(msg);
    }
  }

  info(message: string, meta?: any): void {
    if (this.shouldLog(LogLevel.INFO)) {
      const msg = this.formatMessage("INFO", message, meta);
      console.log(msg);
    }
  }

  debug(message: string, meta?: any): void {
    if (this.shouldLog(LogLevel.DEBUG)) {
      const msg = this.formatMessage("DEBUG", message, meta);
      console.log(msg);
    }
  }

  dev(message: string, meta?: any): void {
    const msg = this.formatMessage("DEV", message, meta);
    console.log(msg);
  }
}

export const logger = new Logger();
export default logger;
