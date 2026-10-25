unit module School;
use RedSourcing;
use RedSourcing::Storage;
use RedSourcing::Journal;

class StudentRegistered does Event is export {
    has Str $.student-id is required;
    has Str $.name is required;
}
class ClassCreated does Event is export {
    has Str $.class-id is required;
    has Str $.title is required;
}
class StudentEnrolled does Event is export {
    has Str $.student-id is required;
    has Str $.class-id is required;
}
class EnrollmentCancelled does Event is export {
    has Str $.student-id is required;
    has Str $.class-id is required;
}

aggregate Student is export {
    has Str $.student-id is entity-id;
    has Str $.name = '';
    method APPLY(StudentRegistered $event) { $!name = $event.name }
    method register(Str :$name! where *.chars) is command {
        unless $!name.chars { self.student-registered: :$name }
        $!name
    }
}

aggregate SchoolClass is export {
    has Str $.class-id is entity-id;
    has Str $.title = '';
    method APPLY(ClassCreated $event) { $!title = $event.title }
    method register(Str :$title! where *.chars) is command {
        unless $!title.chars { self.class-created: :$title }
        $!title
    }
}

projection StudentClasses is export {
    has Str $.student-id is entity-id;
    has Bool $.exists = False;
    has Str $.name = '';
    has %.classes;
    multi method APPLY(StudentRegistered $event where { .student-id eqv $!student-id }) {
        $!exists = True; $!name = $event.name;
    }
    multi method APPLY(StudentEnrolled $event where { .student-id eqv $!student-id }) {
        %!classes{$event.class-id} = True;
    }
    multi method APPLY(EnrollmentCancelled $event where { .student-id eqv $!student-id }) {
        %!classes{$event.class-id}:delete;
    }
    method class-count { %!classes.elems }
}

projection ClassRoster is export {
    has Str $.class-id is entity-id;
    has Bool $.exists = False;
    has Str $.title = '';
    has %.students;
    multi method APPLY(ClassCreated $event where { .class-id eqv $!class-id }) {
        $!exists = True; $!title = $event.title;
    }
    multi method APPLY(StudentEnrolled $event where { .class-id eqv $!class-id }) {
        %!students{$event.student-id} = True;
    }
    multi method APPLY(EnrollmentCancelled $event where { .class-id eqv $!class-id }) {
        %!students{$event.student-id}:delete;
    }
    method student-count { %!students.elems }
}

aggregate Enrollment is export {
    has Str $.student-id is entity-id;
    has Str $.class-id is entity-id;
    has Bool $.active = False;
    multi method APPLY(StudentEnrolled $) { $!active = True }
    multi method APPLY(EnrollmentCancelled $) { $!active = False }

    method enroll is command {
        decision-model(
            (StudentClasses) => %(:$!student-id), (ClassRoster) => %(:$!class-id),
            -> $student, $class {
                die "Unknown student: $!student-id" unless $student.exists;
                die "Unknown class: $!class-id" unless $class.exists;
                do if $!active { False } else {
                    die 'Student already participates in 10 classes' if $student.class-count >= 10;
                    die 'Class already has 30 students' if $class.student-count >= 30;
                    self.student-enrolled;
                    True
                }
            },
        )
    }
    method cancel is command {
        do if $!active { self.enrollment-cancelled; True } else { False }
    }
}

projection SchoolOverview is export {
    has %.students;
    has %.classes;
    has %.enrollments;
    multi method APPLY(StudentRegistered $event) { %!students{$event.student-id} = $event.name }
    multi method APPLY(ClassCreated $event) { %!classes{$event.class-id} = $event.title }
    multi method APPLY(StudentEnrolled $event) {
        %!enrollments{$event.student-id}{$event.class-id} = True;
    }
    multi method APPLY(EnrollmentCancelled $event) {
        %!enrollments{$event.student-id}{$event.class-id}:delete;
    }
    method enrollment-count is query { [+] %!enrollments.values.map: *.elems }
}

sub ensure($proxy) {
    my $stream = $proxy.^stream-name;
    my $type = $proxy.^entity-type.^name;
    $proxy.^create unless storage-stream-exists(journal-connection(), $type, $stream);
    $proxy
}

class App is export {
    method initialize {
        .^create-table: :unless-exists for StoredEvent, StoredCommand;
        self
    }
    method add-student(Str $id, Str $name) { ensure(Student.^with-ids(:student-id($id))).register: :$name }
    method add-class(Str $id, Str $title) { ensure(SchoolClass.^with-ids(:class-id($id))).register: :$title }
    method enrollment(Str $student-id, Str $class-id) { ensure(Enrollment.^with-ids(:$student-id, :$class-id)) }
    method enroll(Str $student-id, Str $class-id) { self.enrollment($student-id, $class-id).enroll }
    method cancel(Str $student-id, Str $class-id) { self.enrollment($student-id, $class-id).cancel }
    method student(Str $student-id) { StudentClasses.^with-ids(:$student-id).^load }
    method classroom(Str $class-id) { ClassRoster.^with-ids(:$class-id).^load }
    method summary { SchoolOverview.^with-ids.^load }
}
