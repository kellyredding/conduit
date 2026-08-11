module ConduitVPN
  # Base for every failure Conduit anticipates and can describe in a sentence:
  # a missing client, a refused profile, an unreadable setting.
  #
  # The distinction is deliberate rather than decorative. Descending from this
  # is a claim that the message is fit to be the only thing a user sees, and
  # commands turn it into one line and a non-zero exit. Anything that does not
  # descend from it is a defect, and should surface as a crash with a backtrace
  # instead of being flattened into tidy prose that hides where it came from.
  class Error < Exception
  end
end
