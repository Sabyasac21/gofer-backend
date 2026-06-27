// services/worker-service/src/middleware/auth.js

const authMiddleware = (req, res, next) => {
  const token = req.headers.authorization?.split(' ')[1];

  if (!token) {
    return res.status(401).json({
      success: false,
      error: { message: 'Missing authorization token' }
    });
  }

  // TODO: Verify JWT token
  req.user = { id: 'user-id' };
  next();
};

module.exports = authMiddleware;
