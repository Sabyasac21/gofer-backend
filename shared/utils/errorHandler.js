// shared/utils/errorHandler.js

const logger = require('./logger');

class AppError extends Error {
  constructor(message, statusCode) {
    super(message);
    this.statusCode = statusCode;
    Error.captureStackTrace(this, this.constructor);
  }
}

class ValidationError extends AppError {
  constructor(message) {
    super(message, 400);
  }
}

class NotFoundError extends AppError {
  constructor(message) {
    super(message, 404);
  }
}

class AuthenticationError extends AppError {
  constructor(message) {
    super(message, 401);
  }
}

class AuthorizationError extends AppError {
  constructor(message) {
    super(message, 403);
  }
}

class ConflictError extends AppError {
  constructor(message) {
    super(message, 409);
  }
}

const errorHandler = (err, req, res, next) => {
  const statusCode = err.statusCode || 500;
  const message = err.message || 'Internal Server Error';
  const requestId = req.requestId || req.get?.('x-request-id') || null;

  logger.error('Request failed', {
    event: 'request_failed',
    requestId,
    operation: err.operation || null,
    method: req.method,
    path: req.originalUrl || req.path,
    statusCode,
    errorName: err.name || 'Error',
    errorCode: err.code || null,
    errorMessage: message,
    errorDetail: err.detail || null,
    errorConstraint: err.constraint || null,
    stack: err.stack || null,
  });

  res.status(statusCode).json({
    success: false,
    error: {
      message,
      statusCode,
      requestId,
      ...(process.env.NODE_ENV === 'development' && { stack: err.stack })
    }
  });
};

module.exports = {
  AppError,
  ValidationError,
  NotFoundError,
  AuthenticationError,
  AuthorizationError,
  ConflictError,
  errorHandler
};
