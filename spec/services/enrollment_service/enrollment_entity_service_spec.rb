require 'spec_helper'

module EnrollmentService
  describe EnrollmentEntityService do
    let(:spaces) { 2.times.map { Factory(:space) } }
    let(:subjects) do
      spaces.map do |space|
        2.times.map { Factory(:subject, :space => space) }
      end.flatten
    end

    subject { EnrollmentEntityService.new(:subject => subjects) }

    context "#create" do
      it "should delegate to insert with correct arguments" do
        columns = []
        subjects.each do |subj|
          space = subj.space
          space.user_space_associations.each do |uca|
            columns << [uca.user_id, subj.id, uca.role.to_s]
          end
        end

        subject.importer.should_receive(:insert).with(columns)

        subject.create
      end

      it "should accept an optional list of [[user, role]]" do
        users = 2.times.collect { Factory(:user) }
        user_role_pairs = users.collect { |u| [u, Role[:member]] }

        records = []
        subjects.each do |s|
          user_role_pairs.each do |(user, role)|
            records << [user.id, s.id, role]
          end
        end

        subject.importer.should_receive(:insert).with(records)

        subject.create(user_role_pairs)
      end
    end

    context "#destroy" do
      let!(:enrollments) do
        subjects.map do |sub|
          3.times.map { Factory(:enrollment, :subject => sub) }
        end.flatten
      end
      let(:users) { enrollments.map(&:user) }

      it "should accept a single user as argument" do
        expect {
          subject.destroy(users.first)
        }.to_not raise_error
      end

      it "should remove the correct quantity of enrollments" do
        expect {
          subject.destroy(users)
        }.to change(Enrollment, :count).by(-enrollments.length)
      end

      it "should remove correct enrollments" do
        subject.destroy(users)
        subjects.map { |s| s.reload }
        subjects.map(&:enrollments).flatten.to_set.should_not be_superset \
          enrollments.to_set
      end
    end

    context "#update_grade" do
      let(:enrollment) do
        Factory(:enrollment, :subject => nil)
      end
      let!(:asset_reports) do
        FactoryGirl.create_list(:asset_report, 3, :enrollment => enrollment)
      end
      subject { EnrollmentEntityService.new(:enrollment => enrollment) }

      it "should wrap enrollments" do
        subject.enrollments.should =~ [enrollment]
      end

      it "should invoke GradeCalculator#calculate_grade" do
        calculator = mock('GradeCalculator')

        GradeCalculator.stub(:new).and_return(calculator)
        calculator.should_receive(:calculate_grade).and_return([[11,11,"member"]])

        subject.update_grade
      end
    end
  end
end
