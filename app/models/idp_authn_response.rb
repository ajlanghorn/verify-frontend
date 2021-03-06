class IdpAuthnResponse < Api::Response
  attr_reader :idp_result, :is_registration, :loa_achieved
  validates_presence_of :idp_result
  validates_inclusion_of :loa_achieved, in: ['LEVEL_1', 'LEVEL_2', nil]
  validates_inclusion_of :is_registration, in: [true, false]

  def initialize(hash)
    @idp_result = hash['idpResult']
    @is_registration = hash['isRegistration']
    @loa_achieved = hash['loaAchieved']
  end
end
