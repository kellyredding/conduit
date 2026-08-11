require "../spec_helper"

private alias Sensitivity = ConduitVPN::Sensitivity

describe ConduitVPN::Sensitivity do
  describe ".sensitive?" do
    it "matches on the default pattern regardless of case" do
      SpecHelper.with_env({"CONDUIT_SENSITIVE_PATTERN" => nil}) do
        Sensitivity.sensitive?("Prod-Alpha").should be_true
        Sensitivity.sensitive?("production").should be_true
        Sensitivity.sensitive?("PROD").should be_true
      end
    end

    it "leaves everything else alone" do
      SpecHelper.with_env({"CONDUIT_SENSITIVE_PATTERN" => nil}) do
        Sensitivity.sensitive?("Alpha").should be_false
        Sensitivity.sensitive?("Bravo").should be_false
      end
    end

    it "honors a replacement pattern" do
      SpecHelper.with_env({"CONDUIT_SENSITIVE_PATTERN" => "(?i)alpha|bravo"}) do
        Sensitivity.sensitive?("Alpha").should be_true
        Sensitivity.sensitive?("Bravo").should be_true
        Sensitivity.sensitive?("Prod-Alpha").should be_true
        Sensitivity.sensitive?("Charlie").should be_false
      end
    end

    # Emptying a setting means "stop doing this". Handing an empty string to a
    # regular expression would instead match every profile — turning the
    # request off into guarding everything.
    it "treats an empty pattern as switching the check off" do
      SpecHelper.with_env({"CONDUIT_SENSITIVE_PATTERN" => ""}) do
        Sensitivity.sensitive?("Prod-Alpha").should be_false
        Sensitivity.pattern?.should be_nil
      end
    end

    it "reports an unusable pattern instead of silently matching nothing" do
      SpecHelper.with_env({"CONDUIT_SENSITIVE_PATTERN" => "(unclosed"}) do
        expect_raises(Sensitivity::BadPattern, "config set") do
          Sensitivity.sensitive?("Alpha")
        end
      end
    end
  end

  describe ".guard!" do
    it "allows anything the pattern does not match, unconfirmed" do
      SpecHelper.with_env({"CONDUIT_SENSITIVE_PATTERN" => nil}) do
        Sensitivity.guard!("Alpha", confirmed: false)
      end
    end

    it "refuses a matching profile that was not confirmed" do
      SpecHelper.with_env({"CONDUIT_SENSITIVE_PATTERN" => nil}) do
        expect_raises(Sensitivity::Refused, "Prod-Alpha") do
          Sensitivity.guard!("Prod-Alpha", confirmed: false)
        end
      end
    end

    # The message is often relayed by something that is not a person, so it
    # has to name the profile rather than say "the profile".
    it "names the profile in the refusal" do
      SpecHelper.with_env({"CONDUIT_SENSITIVE_PATTERN" => nil}) do
        message = begin
          Sensitivity.guard!("Prod-Alpha", confirmed: false)
          ""
        rescue error : Sensitivity::Refused
          error.message.to_s
        end

        message.should contain("Prod-Alpha")
        message.should contain("--yes")
      end
    end

    it "allows a matching profile once confirmed" do
      SpecHelper.with_env({"CONDUIT_SENSITIVE_PATTERN" => nil}) do
        Sensitivity.guard!("Prod-Alpha", confirmed: true)
      end
    end
  end
end
